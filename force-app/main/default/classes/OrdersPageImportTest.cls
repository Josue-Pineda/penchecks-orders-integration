@IsTest
private class OrdersPageImportTest {
    private static final String ACCOUNT_ID = 'acct_8f3c2a';
    private static final String SNAPSHOT_DATE = '2026-10-12T14:03:11Z';

    @TestSetup
    static void linkAccount() {
        insert new Account(Name = 'Northwind Plan Sponsor LLC', Orders_External_Id__c = ACCOUNT_ID);
    }

    @IsTest
    static void importsCreatedOrdersWithMoneyAndReturnsNextPage() {
        Test.setMock(HttpCalloutMock.class, new PageResponse(1, 2, 1));
        Test.startTest();
        OrdersPageImport.Result result = OrdersPageImport.run(ACCOUNT_ID, 1);
        assertInsertBudget(1);
        Test.stopTest();
        Assert.areEqual(200, result.httpStatus);
        Assert.areEqual(2, result.nextPage);
        Assert.areEqual(1, result.changedCount);
        Orders_Order__c imported = [
            SELECT Name, Status__c, Amount__c, Currency_Code__c, Amount_Source_Updated_At__c
            FROM Orders_Order__c WHERE External_Id__c = 'ord_1'
        ];
        Assert.areEqual('created', imported.Status__c);
        Assert.areEqual('OR-1', imported.Name);
        Assert.areEqual(Decimal.valueOf('1250.00'), imported.Amount__c);
        Assert.areEqual('USD', imported.Currency_Code__c);
        Assert.areEqual(Datetime.newInstanceGmt(2026, 10, 12, 14, 3, 11), imported.Amount_Source_Updated_At__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Event__c]);
    }

    @IsTest
    static void fullPageUsesTheSameBoundedStatementBudget() {
        Test.setMock(HttpCalloutMock.class, new PageResponse(1, null, 50));
        Test.startTest();
        OrdersPageImport.Result result = OrdersPageImport.run(ACCOUNT_ID, 1);
        assertInsertBudget(50);
        Test.stopTest();
        Assert.areEqual(50, result.changedCount);
        Assert.isNull(result.nextPage);
        Assert.areEqual(50, [
            SELECT COUNT() FROM Orders_Order__c WHERE Status__c = 'created' AND Currency_Code__c = 'USD'
        ]);
    }

    @IsTest
    static void lowerStageSnapshotEnrichesAmountWithoutUndoingStatus() {
        Account linked = [SELECT Id FROM Account WHERE Orders_External_Id__c = :ACCOUNT_ID];
        Datetime sentAt = Datetime.newInstanceGmt(2026, 10, 10, 0, 0, 0);
        insert new Orders_Order__c(
            Account__c = linked.Id, External_Id__c = 'ord_1', Name = 'OR-1',
            Status__c = 'sent', Source_Updated_At__c = sentAt
        );
        Test.setMock(HttpCalloutMock.class, new PageResponse(2, null, 1));
        Test.startTest();
        OrdersPageImport.Result result = OrdersPageImport.run(ACCOUNT_ID, 2);
        Test.stopTest();
        Assert.isNull(result.nextPage);
        Assert.areEqual(1, result.changedCount);
        Orders_Order__c projected = [
            SELECT Status__c, Source_Updated_At__c, Amount__c
            FROM Orders_Order__c WHERE External_Id__c = 'ord_1'
        ];
        Assert.areEqual('sent', projected.Status__c);
        Assert.areEqual(sentAt, projected.Source_Updated_At__c);
        Assert.areEqual(Decimal.valueOf('1250.00'), projected.Amount__c);
    }

    @IsTest
    static void olderAmountCannotOverwriteNewerSnapshot() {
        Account linked = [SELECT Id FROM Account WHERE Orders_External_Id__c = :ACCOUNT_ID];
        Datetime amountAt = Datetime.newInstanceGmt(2026, 10, 15, 0, 0, 0);
        insert new Orders_Order__c(
            Account__c = linked.Id, External_Id__c = 'ord_1', Name = 'OR-1',
            Status__c = 'sent', Source_Updated_At__c = amountAt,
            Amount__c = 20, Currency_Code__c = 'EUR', Amount_Source_Updated_At__c = amountAt
        );
        Test.setMock(HttpCalloutMock.class, new PageResponse(1, null, 1));
        Test.startTest();
        OrdersPageImport.Result result = OrdersPageImport.run(ACCOUNT_ID, 1);
        Test.stopTest();
        Assert.areEqual(0, result.changedCount);
        Orders_Order__c projected = [
            SELECT Amount__c, Currency_Code__c, Amount_Source_Updated_At__c
            FROM Orders_Order__c WHERE External_Id__c = 'ord_1'
        ];
        Assert.areEqual(Decimal.valueOf('20'), projected.Amount__c);
        Assert.areEqual('EUR', projected.Currency_Code__c);
        Assert.areEqual(amountAt, projected.Amount_Source_Updated_At__c);
    }

    @IsTest
    static void leadsOperatorsToRetrySamePageOn429() {
        Test.setMock(HttpCalloutMock.class, new PageResponse(1, null, null));
        Test.startTest();
        OrdersPageImport.Result result = OrdersPageImport.run(ACCOUNT_ID, 1);
        Test.stopTest();
        Assert.areEqual(429, result.httpStatus);
        Assert.areEqual(1, result.nextPage);
        Assert.areEqual('23', result.retryAfterSeconds);
        Assert.areEqual(0, result.changedCount);
        Assert.areEqual(0, [SELECT COUNT() FROM Orders_Order__c]);
    }

    private static void assertInsertBudget(Integer rows) {
        Assert.areEqual(1, Limits.getCallouts(), 'One source request regardless of page size.');
        Assert.areEqual(2, Limits.getQueries(), 'One Account lock and one lookup for all order IDs.');
        Assert.areEqual(3, Limits.getDmlStatements(), 'One collection insert, plus setting and releasing the savepoint.');
        Assert.areEqual(rows, Limits.getDmlRows(), 'Every order consumes a DML row, even in a bulk statement.');
    }

    private class PageResponse implements HttpCalloutMock {
        private final Integer requestedPage;
        private final Integer nextPage;
        private final Integer itemCount;

        PageResponse(Integer requestedPage, Integer nextPage, Integer itemCount) {
            this.requestedPage = requestedPage;
            this.nextPage = nextPage;
            this.itemCount = itemCount;
        }

        public HttpResponse respond(HttpRequest request) {
            Assert.areEqual('GET', request.getMethod());
            Assert.areEqual(
                'callout:Orders_API/accounts/' + ACCOUNT_ID + '/orders?page=' + requestedPage + '&pageSize=50',
                request.getEndpoint()
            );
            HttpResponse response = new HttpResponse();
            if (itemCount == null) {
                response.setStatusCode(429);
                response.setHeader('Retry-After', '23');
                return response;
            }
            List<Map<String, Object>> items = new List<Map<String, Object>>();
            for (Integer index = 1; index <= itemCount; index++) {
                items.add(new Map<String, Object>{
                    'id' => 'ord_' + index, 'friendlyId' => 'OR-' + index, 'accountId' => ACCOUNT_ID,
                    'status' => 'created', 'updatedAt' => SNAPSHOT_DATE,
                    'amount' => new Map<String, String>{ 'value' => '1250.00', 'currency' => 'USD' }
                });
            }
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{'nextPage' => nextPage, 'items' => items}));
            return response;
        }
    }
}
