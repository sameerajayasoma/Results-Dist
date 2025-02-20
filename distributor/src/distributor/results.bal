import ballerina/http;
import ballerina/log;
import ballerina/mime;
import ballerina/websub;

# Service for results tabulation to publish results to. We assume that results tabulation will deliver
# a result in two separate messages - one with the json result data and another with an image of the
# signed result document with both messages referring to the same message code which must be unique
# per result. We also assume that the results data will come first (as that's what creates the row)
# and then the image.
# 
# The two message approach is done only to make it easier for the publisher - the approach of using 
# a multipart/x (x = alternative or related) would've been better. 
# 
# Both will be saved for resilience and later access for subscribers who want it.

@http:ServiceConfig {
    basePath: "/result",
    auth: {
        scopes: ["publisher"]
    }
}
service receiveResults on resultsListener {
    @http:ResourceConfig {
        methods: ["POST"],
        path: "/data/{electionCode}/{resultType}/{resultCode}",
        body: "jsonResult"
    }
    resource function receiveData(http:Caller caller, http:Request req, string electionCode, string resultType, 
                                  string resultCode, json jsonResult) returns error? {
        // payload is supposed to be a json object - its ok to get upset if not
        map<json> jsonobj = check trap <map<json>> jsonResult;

        // save everything in a convenient way
        Result result = <@untainted> {
            sequenceNo: -1, // wil be updated with DB sequence # upon storage
            election: electionCode,
            'type: resultType,
            code: resultCode,
            jsonResult: <map<json>> jsonResult,
            imageMediaType: (),
            imageData: ()
        };
        log:printInfo("Result data received for " + electionCode +  "/" + resultType + "/" + resultCode);

        // store the result in the DB against the resultCode and assign it a sequence #
        check saveResult(result);
    
        // publish the received result
        publishResultData(result);

        // respond accepted
        return caller->accepted();
     }

    @http:ResourceConfig {
        methods: ["POST"],
        path: "/image/{electionCode}/{resultCode}",
        body: "imageData"
    }
    resource function receiveImage(http:Caller caller, http:Request req, string electionCode, string resultCode, 
                                   byte[] imageData) returns error? {
        log:printInfo("Result image received for " + electionCode +  "/" + resultCode);

        string mediaType = req.getContentType();

        // store the image in the DB against the resultCode
        check saveImage(<@untainted> electionCode, <@untainted> resultCode, <@untainted> mediaType, <@untainted> imageData);

        // respond accepted
        return caller->accepted();
    }

    resource function reset(http:Caller caller, http:Request req) returns error? {
        log:printInfo("Resetting all results ..");
        check resetResults();
        return  caller->accepted();
    }
}

# Publish the results as follows:
# - send SMSs to all subscribers
# - update the website with the result
# - deliver the result data to all subscribers
function publishResultData(Result result) {
        worker smsWorker {
            // Send SMS to all subscribers.
            // TODO - should we ensure SMS is sent first?
        }

        worker jsonWorker returns error? {
            websub:WebSubHub wh = <websub:WebSubHub> hub; // safe .. working around type guard limitation

            // push it out with the election code and the json result as the message
            json resultAll = {
                election_code : result.election,
                result : result.jsonResult
            };
            var r = wh.publishUpdate(JSON_RESULTS_TOPIC, resultAll, mime:APPLICATION_JSON);
            if r is error {
                log:printError("Error publishing update: ", r);
            }
        }
}
