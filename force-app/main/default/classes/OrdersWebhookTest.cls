@IsTest
private class OrdersWebhookTest {
    private static final String FIXTURE_SECRET = 'orders-takehome-2026';
    private static final String SUBSCRIPTION = 'sub_a1b2c3d4e5f67890abcdef12';
    private static final String DATE_SENT = '2026-10-12T14:03:11Z';

    @TestSetup
    static void configureSecret() {
        insert new Orders_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Webhook_Secret__c = FIXTURE_SECRET,
            Expected_Subscription_Id__c = SUBSCRIPTION
        );
    }

    @IsTest
    static void deduplicatesAndKeepsStatusPerOrder() {
        Blob start = payload('evt_001', 'inProgress', '2026-10-10T10:00:00Z', 'acct_8f3c2a', 'ord_77d1e9');
        expect(start, signature(start), 200, 'Applied');
        send('evt_002', 'waitingForParticipant', '2026-10-11T10:00:00Z', 'ord_77d1e9', 'Applied');
        expect(start, signature(start), 200, 'Duplicate');
        send('evt_004', 'sent', '2026-10-12T14:03:11Z', 'ord_77d1e9', 'Applied');
        send('evt_003', 'cleared', '2026-10-09T09:41:27Z', 'ord_52ab10', 'Applied');
        send('evt_old', 'inProgress', '2026-10-10T11:00:00Z', 'ord_77d1e9', 'IgnoredStale');

        Map<String, String> statusByOrder = new Map<String, String>();
        for (Orders_Order__c record : [
            SELECT External_Id__c, Status__c, Account__r.Orders_External_Id__c FROM Orders_Order__c
        ]) {
            Assert.areEqual('acct_8f3c2a', record.Account__r.Orders_External_Id__c);
            statusByOrder.put(record.External_Id__c, record.Status__c);
        }
        Assert.areEqual(new Map<String, String>{'ord_77d1e9' => 'sent', 'ord_52ab10' => 'cleared'}, statusByOrder);
        Assert.areEqual(1, [SELECT COUNT() FROM Orders_Event__c WHERE External_Id__c = 'evt_001']);
        Assert.areEqual(5, [SELECT COUNT() FROM Orders_Event__c]);
    }

    @IsTest
    static void rejectsTamperedOrUnsignedRequestsWithoutWriting() {
        Blob original = payload('evt_001', 'sent', DATE_SENT, 'acct_8f3c2a', 'ord_77d1e9');
        Blob altered = Blob.valueOf(original.toString() + ' ');
        expect(altered, signature(original), 403, 'InvalidSignature');
        expect(original, null, 403, 'InvalidSignature');
        expect(original, 'abcd', 403, 'InvalidSignature');
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Event__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Order__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void refusesEmptyOversizedAndUnconfiguredDeliveriesWithoutWriting() {
        expect(Blob.valueOf(''), signature(Blob.valueOf('')), 400, 'MissingBody');
        Blob oversized = Blob.valueOf('x'.repeat(16385));
        expect(oversized, signature(oversized), 413, 'BodyTooLarge');
        delete [SELECT Id FROM Orders_Settings__c];
        Blob valid = payload('evt_unconfigured', 'sent', DATE_SENT, 'acct_8f3c2a', 'ord_77d1e9');
        expect(valid, signature(valid), 500, 'WebhookConfigurationMissing');
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Event__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Order__c]);
    }

    @IsTest
    static void acknowledgesAndDeduplicatesPermanentFailures() {
        Blob malformed = Blob.valueOf('{malformed');
        Assert.areEqual('InvalidJson', expect(malformed, signature(malformed), 200, 'Rejected').get('reason'));
        expect(malformed, signature(malformed), 200, 'Duplicate');
        Blob badDate = payload('evt_bad_date', 'sent', 'yesterday', 'acct_8f3c2a', 'ord_77d1e9');
        Assert.areEqual('InvalidEnvelope', expect(badDate, signature(badDate), 200, 'Rejected').get('reason'));
        Blob unknown = payload('evt_unknown', 'cancelled', DATE_SENT, 'acct_8f3c2a', 'ord_77d1e9');
        Assert.areEqual('UnsupportedEventType', expect(unknown, signature(unknown), 200, 'Unsupported').get('reason'));
        Blob futureVersion = payload('evt_future', 'sent', DATE_SENT, 'acct_8f3c2a', 'ord_77d1e9', SUBSCRIPTION, '1.1');
        Assert.areEqual('UnsupportedVersion', expect(futureVersion, signature(futureVersion), 200, 'Unsupported').get('reason'));

        List<Orders_Event__c> malformedReceipts = [
            SELECT Reason__c, External_Id__c, Rejected_Body_Digest__c FROM Orders_Event__c WHERE Reason__c = 'InvalidJson'
        ];
        Assert.areEqual(1, malformedReceipts.size());
        Assert.isNull(malformedReceipts[0].External_Id__c);
        Assert.isNotNull(malformedReceipts[0].Rejected_Body_Digest__c);
        Orders_Event__c unsupported = [
            SELECT Outcome__c, Account_External_Id__c, Order_External_Id__c, Subscription_Id__c
            FROM Orders_Event__c WHERE External_Id__c = 'evt_unknown'
        ];
        Assert.areEqual('Unsupported', unsupported.Outcome__c);
        Assert.areEqual('acct_8f3c2a', unsupported.Account_External_Id__c);
        Assert.areEqual('ord_77d1e9', unsupported.Order_External_Id__c);
        Assert.areEqual(SUBSCRIPTION, unsupported.Subscription_Id__c);
        Assert.areEqual(4, [SELECT COUNT() FROM Orders_Event__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Order__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void unexpectedSubscriptionCannotClaimTheExpectedSubscriptionEventId() {
        Blob wrong = payload('evt_shared', 'sent', DATE_SENT, 'acct_8f3c2a', 'ord_77d1e9', 'sub_other', '1.0');
        Assert.areEqual('UnexpectedSubscription', expect(wrong, signature(wrong), 200, 'Rejected').get('reason'));
        expect(wrong, signature(wrong), 200, 'Duplicate');
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Event__c WHERE External_Id__c = 'evt_shared']);
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Order__c]);
        send('evt_shared', 'sent', DATE_SENT, 'ord_77d1e9', 'Applied');
        Assert.areEqual(1, [SELECT COUNT() FROM Orders_Event__c WHERE External_Id__c = 'evt_shared']);
        Assert.areEqual(2, [SELECT COUNT() FROM Orders_Event__c]);
    }

    @IsTest
    static void rollsBackBusinessWritesAndKeepsConflictReceipt() {
        Account other = new Account(Name = 'Existing account', Orders_External_Id__c = 'acct_other');
        insert other;
        Orders_Order__c conflictingOrder = new Orders_Order__c(
            Account__c = other.Id, Name = 'Existing order', External_Id__c = 'ord_77d1e9',
            Status__c = 'inProgress', Source_Updated_At__c = Datetime.newInstanceGmt(2026, 10, 10, 0, 0, 0)
        );
        insert conflictingOrder;
        Blob delivery = payload('evt_conflict', 'sent', DATE_SENT, 'acct_8f3c2a', 'ord_77d1e9');
        Assert.areEqual('AccountOrderMismatch', expect(delivery, signature(delivery), 200, 'Conflict').get('reason'));
        expect(delivery, signature(delivery), 200, 'Duplicate');
        Orders_Event__c receipt = [
            SELECT Outcome__c, Reason__c FROM Orders_Event__c WHERE External_Id__c = 'evt_conflict'
        ];
        Assert.areEqual('Conflict', receipt.Outcome__c);
        Assert.areEqual('AccountOrderMismatch', receipt.Reason__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Orders_Event__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Orders_External_Id__c = 'acct_8f3c2a']);
        Assert.areEqual('inProgress', [SELECT Status__c FROM Orders_Order__c WHERE Id = :conflictingOrder.Id].Status__c);
    }

    @IsTest
    static void acceptsReturnAndRejectsRegressionEvenWithNewerTimestamp() {
        send('evt_sent', 'sent', '2026-10-10T10:00:00Z', 'ord_1', 'Applied');
        send('evt_returned', 'returned', '2026-10-11T10:00:00Z', 'ord_1', 'Applied');
        send('evt_bad_regression', 'cleared', '2026-10-12T10:00:00Z', 'ord_1', 'IgnoredStale');
        send('evt_cleared', 'cleared', '2026-10-10T10:00:00Z', 'ord_2', 'Applied');
        send('evt_returned_2', 'returned', '2026-10-11T10:00:00Z', 'ord_2', 'Applied');
        Assert.areEqual(2, [SELECT COUNT() FROM Orders_Order__c WHERE Status__c = 'returned']);
    }

    private static void send(String eventId, String status, String occurredAt, String orderId, String outcome) {
        Blob body = payload(eventId, status, occurredAt, 'acct_8f3c2a', orderId);
        expect(body, signature(body), 200, outcome);
    }

    private static Map<String, Object> expect(Blob body, String digest, Integer expectedCode, String expectedOutcome) {
        RestRequest request = new RestRequest();
        request.requestUri = '/services/apexrest/orders/v1/events';
        request.httpMethod = 'POST';
        request.requestBody = body;
        if (digest != null) {
            request.addHeader('orders-signature', digest);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        OrdersWebhook.post();
        Assert.areEqual(expectedCode, RestContext.response.statusCode, RestContext.response.responseBody.toString());
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Assert.areEqual(expectedOutcome, (String) result.get('outcome'));
        return result;
    }

    private static String signature(Blob body) {
        return EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', body, Blob.valueOf(FIXTURE_SECRET)));
    }

    private static Blob payload(String eventId, String status, String occurredAt, String accountId, String orderId) {
        return payload(eventId, status, occurredAt, accountId, orderId, SUBSCRIPTION, '1.0');
    }

    private static Blob payload(
        String eventId, String status, String occurredAt, String accountId, String orderId,
        String subscriptionId, String version
    ) {
        return Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'subscriptionId' => subscriptionId,
            'event' => new Map<String, Object>{
                'id' => eventId, 'type' => 'order.' + status, 'occurredAt' => occurredAt, 'version' => version
            },
            'data' => new Map<String, Object>{
                'orderId' => orderId, 'orderFriendlyId' => 'OR-' + orderId,
                'accountId' => accountId, 'accountFriendlyId' => 'AC-260914-017-2231'
            }
        }));
    }
}
