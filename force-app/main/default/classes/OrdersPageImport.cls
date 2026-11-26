public with sharing class OrdersPageImport {
    public class ImportFailureException extends Exception {}

    public class Result {
        public Integer httpStatus { get; private set; }
        public Integer nextPage { get; private set; }
        public Integer changedCount { get; private set; }
        public String retryAfterSeconds { get; private set; }

        private Result(Integer httpStatus, Integer nextPage, Integer changedCount, String retryAfterSeconds) {
            this.httpStatus = httpStatus;
            this.nextPage = nextPage;
            this.changedCount = changedCount;
            this.retryAfterSeconds = retryAfterSeconds;
        }
    }

    public static Result run(String accountId, Integer page) {
        OrdersContract.textValue(accountId, 'accountId', 100);
        if (page == null || page < 1) {
            throw new ImportFailureException('Page must be a positive integer.');
        }

        HttpResponse response = OrdersApiClient.get(
            '/accounts/' + OrdersApiClient.pathSegment(accountId) + '/orders?page=' + page + '&pageSize=50'
        );
        if (response.getStatusCode() == 429) {
            return new Result(429, page, 0, OrdersApiClient.retryAfterSeconds(response));
        }
        if (response.getStatusCode() != 200) {
            throw new ImportFailureException('Orders returned HTTP ' + response.getStatusCode() + '.');
        }

        Map<String, Object> body = OrdersContract.objectValue(JSON.deserializeUntyped(response.getBody()), 'page');
        Object rawItems = body.get('items');
        if (!(rawItems instanceof List<Object>) || ((List<Object>) rawItems).size() > 50 || !body.containsKey('nextPage')) {
            throw new ImportFailureException('Invalid Orders page.');
        }
        Object cursor = body.get('nextPage');
        if (cursor != null && (!(cursor instanceof Integer) || (Integer) cursor <= page)) {
            throw new ImportFailureException('Invalid Orders page cursor.');
        }

        Set<String> seen = new Set<String>();
        List<OrdersProjection.Change> changes = new List<OrdersProjection.Change>();
        for (Object item : (List<Object>) rawItems) {
            Map<String, Object> order = OrdersContract.objectValue(item, 'items');
            String itemAccountId = OrdersContract.textValue(order.get('accountId'), 'items.accountId', 100);
            String orderId = OrdersContract.textValue(order.get('id'), 'items.id', 100);
            if (!accountId.equals(itemAccountId) || !seen.add(orderId)) {
                throw new ImportFailureException('Invalid account or duplicate order in Orders page.');
            }
            changes.add(new OrdersProjection.Change(
                orderId,
                OrdersContract.textValue(order.get('friendlyId'), 'items.friendlyId', 80),
                OrdersContract.textValue(order.get('status'), 'items.status', 80),
                OrdersContract.timestamp(order.get('updatedAt'), 'items.updatedAt'),
                new OrdersContract.Money(order.get('amount'), 'items.amount')
            ));
        }

        // An operator links the Account and runs each page in a separate Apex transaction.
        Savepoint beforeWrite = Database.setSavepoint();
        try {
            Integer changed = OrdersProjection.apply(accountId, null, changes);
            return new Result(200, (Integer) cursor, changed, null);
        } catch (Exception ex) {
            Database.rollback(beforeWrite);
            throw ex;
        } finally {
            Database.releaseSavepoint(beforeWrite);
        }
    }
}
