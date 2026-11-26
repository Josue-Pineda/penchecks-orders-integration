@RestResource(urlMapping='/orders/v1/events')
global with sharing class OrdersWebhook {
    private static final Integer MAX_BODY_BYTES = 16384;

    @HttpPost
    global static void post() {
        RestRequest request = RestContext.request;
        Blob rawBody = request.requestBody;
        if (rawBody == null || rawBody.size() == 0) {
            respond(400, 'MissingBody');
            return;
        }
        if (rawBody.size() > MAX_BODY_BYTES) {
            respond(413, 'BodyTooLarge');
            return;
        }

        String signature = findSignature(request);
        if (signature == null || !Pattern.matches('[a-fA-F0-9]{64}', signature)) {
            respond(403, 'InvalidSignature');
            return;
        }
        Orders_Settings__c settings = Orders_Settings__c.getOrgDefaults();
        String secret = settings?.Webhook_Secret__c;
        if (String.isBlank(secret)) {
            respond(500, 'WebhookConfigurationMissing');
            return;
        }
        if (!Crypto.verifyHMac('hmacSHA256', rawBody, Blob.valueOf(secret), EncodingUtil.convertFromHex(signature))) {
            respond(403, 'InvalidSignature');
            return;
        }

        OrdersEventService.Delivery delivery = OrdersEventService.read(rawBody, settings.Expected_Subscription_Id__c);
        Savepoint beforeWrite = Database.setSavepoint();
        try {
            OrdersEventService.Result result;
            try {
                result = OrdersEventService.apply(delivery);
            } catch (OrdersProjection.AccountConflictException ex) {
                // Discard the initial claim and any business writes before recording the terminal conflict.
                Database.rollback(beforeWrite);
                result = OrdersEventService.recordOutcome(delivery, 'Conflict', 'AccountOrderMismatch');
            }
            respond(200, result.outcome, delivery.eventId, result.reason);
        } catch (DmlException ex) {
            Database.rollback(beforeWrite);
            String code = ex.getDmlStatusCode(0);
            if ('UNABLE_TO_LOCK_ROW'.equals(code) || 'DUPLICATE_VALUE'.equals(code)) {
                respond(503, 'RetryDelivery', delivery.eventId);
            } else {
                logFailure(delivery.eventId, code);
                respond(500, 'ProcessingFailed', delivery.eventId);
            }
        } catch (QueryException ex) {
            Database.rollback(beforeWrite);
            if (ex.getMessage().contains('UNABLE_TO_LOCK_ROW') || ex.getMessage().contains('record currently unavailable')) {
                respond(503, 'RetryDelivery', delivery.eventId);
            } else {
                logFailure(delivery.eventId, ex.getTypeName());
                respond(500, 'ProcessingFailed', delivery.eventId);
            }
        } catch (Exception ex) {
            Database.rollback(beforeWrite);
            logFailure(delivery.eventId, ex.getTypeName());
            respond(500, 'ProcessingFailed', delivery.eventId);
        } finally {
            Database.releaseSavepoint(beforeWrite);
        }
    }

    private static String findSignature(RestRequest request) {
        for (String name : request.headers.keySet()) {
            if (name.equalsIgnoreCase('Orders-Signature')) {
                return request.headers.get(name);
            }
        }
        return null;
    }

    private static void logFailure(String eventId, String category) {
        System.debug(LoggingLevel.ERROR, 'Orders event ' + eventId + ' failed (' + category + ').');
    }

    private static void respond(Integer code, String outcome) {
        respond(code, outcome, null, null);
    }

    private static void respond(Integer code, String outcome, String eventId) {
        respond(code, outcome, eventId, null);
    }

    private static void respond(Integer code, String outcome, String eventId, String reason) {
        RestContext.response.statusCode = code;
        RestContext.response.addHeader('Content-Type', 'application/json');
        Map<String, Object> body = new Map<String, Object>{'outcome' => outcome};
        if (eventId != null) {
            body.put('eventId', eventId);
        }
        if (reason != null) {
            body.put('reason', reason);
        }
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(body));
    }
}
