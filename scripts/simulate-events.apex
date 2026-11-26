// Signs the spec's sample sequence plus three extra cases and calls the deployed handler directly.
// The curl request in the README sends the same kind of delivery over HTTP.
Organization environment = [SELECT OrganizationType, IsSandbox FROM Organization LIMIT 1];
Assert.isTrue(environment.OrganizationType == 'Developer Edition' && !environment.IsSandbox,
    'Use your personal Developer Edition for this exercise.');
Orders_Settings__c settings = Orders_Settings__c.getOrgDefaults();
Assert.isNotNull(settings?.Webhook_Secret__c, 'Run scripts/setup-demo.apex first.');

// Empty uses the spec's IDs on the Account linked by setup-demo.apex. Set a suffix such as '-run-02' to repeat with fresh records.
String runId = '';
String accountId = 'acct_8f3c2a' + runId;
String accountFriendlyId = 'AC-260914-017-2231' + runId;
String firstOrder = 'ord_77d1e9' + runId;
String secondOrder = 'ord_52ab10' + runId;
List<List<String>> deliveries = new List<List<String>>{
    new List<String>{'evt_001', 'inProgress', '2026-10-10T10:00:00Z', firstOrder, 'Applied'},
    new List<String>{'evt_002', 'waitingForParticipant', '2026-10-11T10:00:00Z', firstOrder, 'Applied'},
    new List<String>{'evt_001', 'inProgress', '2026-10-10T10:00:00Z', firstOrder, 'Duplicate'},
    new List<String>{'evt_004', 'sent', '2026-10-12T14:03:11Z', firstOrder, 'Applied'},
    new List<String>{'evt_003', 'cleared', '2026-10-09T09:41:27Z', secondOrder, 'Applied'},
    new List<String>{'evt_late', 'inProgress', '2026-10-10T11:00:00Z', firstOrder, 'IgnoredStale'},
    new List<String>{'evt_unsupported', 'cancelled', '2026-10-13T10:00:00Z', firstOrder, 'Unsupported'},
    new List<String>{'evt_tampered', 'returned', '2026-10-13T10:00:00Z', firstOrder, 'InvalidSignature'}
};
Set<String> expectedReceiptIds = new Set<String>();
for (List<String> item : deliveries) {
    Boolean tampered = item[4] == 'InvalidSignature';
    String eventId = item[0] + runId;
    if (!tampered) {
        expectedReceiptIds.add(eventId);
    }
    String friendlyId = item[3] == firstOrder ? 'OR-261001-017-2231' : 'OR-260922-017-1187';
    String body = JSON.serialize(new Map<String, Object>{
        'subscriptionId' => 'sub_a1b2c3d4e5f67890abcdef12',
        'event' => new Map<String, Object>{
            'id' => eventId, 'type' => 'order.' + item[1], 'occurredAt' => item[2], 'version' => '1.0'
        },
        'data' => new Map<String, Object>{
            'orderId' => item[3], 'orderFriendlyId' => friendlyId + runId,
            'accountId' => accountId, 'accountFriendlyId' => accountFriendlyId
        }
    });
    Blob signature = Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(settings.Webhook_Secret__c));
    RestRequest request = new RestRequest();
    request.httpMethod = 'POST';
    request.requestUri = '/services/apexrest/orders/v1/events';
    request.requestBody = Blob.valueOf(tampered ? body + ' ' : body);
    request.addHeader('Orders-Signature', EncodingUtil.convertToHex(signature));
    RestContext.request = request;
    RestContext.response = new RestResponse();
    OrdersWebhook.post();
    Assert.areEqual(tampered ? 403 : 200, RestContext.response.statusCode, eventId);
    Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    String outcome = (String) response.get('outcome');
    Assert.isTrue(item[4] == outcome || (!tampered && outcome == 'Duplicate'), eventId + ' → ' + outcome);
    System.debug(LoggingLevel.INFO, eventId + ': HTTP ' + RestContext.response.statusCode + ' ' + outcome);
}

Map<String, String> actual = new Map<String, String>();
for (Orders_Order__c orderRecord : [
    SELECT External_Id__c, Status__c FROM Orders_Order__c
    WHERE Account__r.Orders_External_Id__c = :accountId AND External_Id__c IN (:firstOrder, :secondOrder)
]) {
    actual.put(orderRecord.External_Id__c, orderRecord.Status__c);
}
Assert.areEqual(new Map<String, String>{firstOrder => 'sent', secondOrder => 'cleared'}, actual);
Assert.areEqual(expectedReceiptIds.size(), [
    SELECT COUNT() FROM Orders_Event__c WHERE External_Id__c IN :expectedReceiptIds
]);
String tamperedId = 'evt_tampered' + runId;
Assert.areEqual(0, [SELECT COUNT() FROM Orders_Event__c WHERE External_Id__c = :tamperedId]);
System.debug(LoggingLevel.INFO, 'Verified both order states and the receipt counts for ' + accountId);
