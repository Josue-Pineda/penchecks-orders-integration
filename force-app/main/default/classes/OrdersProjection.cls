public with sharing class OrdersProjection {
    public class AccountConflictException extends Exception {}

    private static final Map<String, Integer> STAGES = new Map<String, Integer>{
        'created' => 0,
        'inProgress' => 1,
        'waitingForParticipant' => 2,
        'sent' => 3,
        'cleared' => 4,
        'returned' => 5
    };

    public class Change {
        public String orderId { get; private set; }
        public String friendlyId { get; private set; }
        public String status { get; private set; }
        public Datetime sourceUpdatedAt { get; private set; }
        public OrdersContract.Money money { get; private set; }

        public Change(String orderId, String friendlyId, String status, Datetime sourceUpdatedAt) {
            this(orderId, friendlyId, status, sourceUpdatedAt, null);
        }

        public Change(
            String orderId, String friendlyId, String status, Datetime sourceUpdatedAt, OrdersContract.Money money
        ) {
            if (!STAGES.containsKey(status)) {
                throw new OrdersContract.InvalidPayloadException('Unknown order status.');
            }
            this.orderId = orderId;
            this.friendlyId = friendlyId;
            this.status = status;
            this.sourceUpdatedAt = sourceUpdatedAt;
            this.money = money;
        }
    }

    public static Integer apply(String accountId, String accountName, List<Change> changes) {
        if (changes.isEmpty()) {
            return 0;
        }

        List<Account> matches = [
            SELECT Id FROM Account
            WHERE Orders_External_Id__c = :accountId
            WITH USER_MODE
            FOR UPDATE
        ];
        Account accountRecord;
        if (matches.isEmpty()) {
            if (String.isBlank(accountName)) {
                throw new AccountConflictException('Link the account in Salesforce before importing orders.');
            }
            accountRecord = new Account(Name = accountName, Orders_External_Id__c = accountId);
            insert as user accountRecord;
        } else {
            accountRecord = matches[0];
        }

        Set<String> orderIds = new Set<String>();
        for (Change change : changes) {
            orderIds.add(change.orderId);
        }
        Map<String, Orders_Order__c> currentByExternalId = new Map<String, Orders_Order__c>();
        for (Orders_Order__c currentOrder : [
            SELECT Id, Account__c, External_Id__c, Status__c, Source_Updated_At__c, Amount_Source_Updated_At__c
            FROM Orders_Order__c
            WHERE External_Id__c IN :orderIds
            WITH USER_MODE
        ]) {
            currentByExternalId.put(currentOrder.External_Id__c, currentOrder);
        }

        List<Orders_Order__c> inserts = new List<Orders_Order__c>();
        List<Orders_Order__c> updates = new List<Orders_Order__c>();
        for (Change change : changes) {
            Orders_Order__c existing = currentByExternalId.get(change.orderId);
            if (existing == null) {
                Orders_Order__c pending = new Orders_Order__c(
                    Account__c = accountRecord.Id, External_Id__c = change.orderId
                );
                writeStatus(pending, change);
                writeAmount(pending, change);
                inserts.add(pending);
                continue;
            }
            if (existing.Account__c != accountRecord.Id) {
                throw new AccountConflictException('Order is already linked to another account.');
            }
            Boolean updateStatus = shouldApply(existing, change);
            Boolean updateAmount = change.money != null && (existing.Amount_Source_Updated_At__c == null
                || change.sourceUpdatedAt > existing.Amount_Source_Updated_At__c);
            if (updateStatus || updateAmount) {
                Orders_Order__c pending = new Orders_Order__c(Id = existing.Id);
                if (updateStatus) {
                    writeStatus(pending, change);
                }
                if (updateAmount) {
                    writeAmount(pending, change);
                }
                updates.add(pending);
            }
        }

        if (!inserts.isEmpty()) {
            insert as user inserts;
        }
        if (!updates.isEmpty()) {
            update as user updates;
        }
        return inserts.size() + updates.size();
    }

    private static void writeStatus(Orders_Order__c orderRecord, Change change) {
        orderRecord.Name = change.friendlyId;
        orderRecord.Status__c = change.status;
        orderRecord.Source_Updated_At__c = change.sourceUpdatedAt;
    }

    private static void writeAmount(Orders_Order__c orderRecord, Change change) {
        if (change.money != null) {
            orderRecord.Amount__c = change.money.amount;
            orderRecord.Currency_Code__c = change.money.currencyCode;
            orderRecord.Amount_Source_Updated_At__c = change.sourceUpdatedAt;
        }
    }

    private static Boolean shouldApply(Orders_Order__c existing, Change change) {
        Integer currentStage = STAGES.get(existing.Status__c);
        Integer incomingStage = STAGES.get(change.status);
        // State ordering wins across stages because snapshot timestamps can include other edits.
        return currentStage == null || incomingStage > currentStage
            || (incomingStage == currentStage
                && (existing.Source_Updated_At__c == null || change.sourceUpdatedAt > existing.Source_Updated_At__c));
    }
}
