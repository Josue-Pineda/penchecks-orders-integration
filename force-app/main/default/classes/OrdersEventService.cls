public with sharing class OrdersEventService {
    private static final Map<String, String> EVENT_STATUSES = new Map<String, String>{
        'order.inProgress' => 'inProgress',
        'order.waitingForParticipant' => 'waitingForParticipant',
        'order.sent' => 'sent',
        'order.cleared' => 'cleared',
        'order.returned' => 'returned'
    };

    public class Delivery {
        public String eventId { get; private set; }
        public String subscriptionId { get; private set; }
        public String eventType { get; private set; }
        public String accountId { get; private set; }
        public String orderId { get; private set; }
        public String accountFriendlyId { get; private set; }
        public Datetime occurredAt { get; private set; }
        public String bodyDigest { get; private set; }
        public String outcome { get; private set; }
        public String reason { get; private set; }
        public OrdersProjection.Change change { get; private set; }
    }

    public class Result {
        public String outcome { get; private set; }
        public String reason { get; private set; }

        private Result(String outcome, String reason) {
            this.outcome = outcome;
            this.reason = reason;
        }
    }

    // The caller authenticates the bytes before asking this service to interpret them.
    public static Delivery read(Blob signedBody, String expectedSubscriptionId) {
        Delivery delivery = new Delivery();
        try {
            inspect(delivery, signedBody, expectedSubscriptionId);
        } catch (System.JSONException ex) {
            delivery.outcome = 'Rejected';
            delivery.reason = 'InvalidJson';
        } catch (StringException ex) {
            delivery.outcome = 'Rejected';
            delivery.reason = 'InvalidJson';
        } catch (OrdersContract.InvalidPayloadException ex) {
            delivery.outcome = 'Rejected';
            delivery.reason = 'InvalidEnvelope';
        }

        if (delivery.eventId == null) {
            // A stable key for repeated identical bytes when the event ID cannot be trusted or read.
            delivery.bodyDigest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', signedBody));
        }
        return delivery;
    }

    private static void inspect(Delivery delivery, Blob signedBody, String expectedSubscriptionId) {
        Map<String, Object> envelope = OrdersContract.objectValue(
            JSON.deserializeUntyped(signedBody.toString()), 'envelope'
        );
        Map<String, Object> info = OrdersContract.optionalObject(envelope.get('event'));
        Map<String, Object> data = OrdersContract.optionalObject(envelope.get('data'));
        delivery.subscriptionId = OrdersContract.optionalText(envelope.get('subscriptionId'), 100);
        delivery.eventId = OrdersContract.optionalText(info.get('id'), 100);
        delivery.eventType = OrdersContract.optionalText(info.get('type'), 80);
        delivery.accountId = OrdersContract.optionalText(data.get('accountId'), 100);
        delivery.orderId = OrdersContract.optionalText(data.get('orderId'), 100);

        if (delivery.subscriptionId == null) {
            delivery.eventId = null;
            throw new OrdersContract.InvalidPayloadException('Subscription identity is missing.');
        }
        if (!String.isBlank(expectedSubscriptionId) && !expectedSubscriptionId.equals(delivery.subscriptionId)) {
            // An unexpected subscription cannot claim an event ID in the configured subscription.
            delivery.eventId = null;
            delivery.outcome = 'Rejected';
            delivery.reason = 'UnexpectedSubscription';
            return;
        }
        if (delivery.eventId == null || delivery.eventType == null) {
            throw new OrdersContract.InvalidPayloadException('Required event identity is missing.');
        }

        String version = OrdersContract.textValue(info.get('version'), 'event.version', 20);
        if (!'1.0'.equals(version)) {
            delivery.outcome = 'Unsupported';
            delivery.reason = 'UnsupportedVersion';
            return;
        }
        if (!EVENT_STATUSES.containsKey(delivery.eventType)) {
            delivery.outcome = 'Unsupported';
            delivery.reason = 'UnsupportedEventType';
            return;
        }
        delivery.occurredAt = OrdersContract.timestamp(info.get('occurredAt'), 'event.occurredAt');
        delivery.accountId = OrdersContract.textValue(delivery.accountId, 'data.accountId', 100);
        delivery.accountFriendlyId = OrdersContract.textValue(data.get('accountFriendlyId'), 'data.accountFriendlyId', 80);
        delivery.change = new OrdersProjection.Change(
            OrdersContract.textValue(delivery.orderId, 'data.orderId', 100),
            OrdersContract.textValue(data.get('orderFriendlyId'), 'data.orderFriendlyId', 80),
            EVENT_STATUSES.get(delivery.eventType),
            delivery.occurredAt
        );
    }

    public static Result apply(Delivery delivery) {
        if (delivery.outcome != null) {
            return recordOutcome(delivery, delivery.outcome, delivery.reason);
        }
        Orders_Event__c receipt = buildReceipt(delivery, 'Applied', null);
        if (!claim(receipt)) {
            return new Result('Duplicate', null);
        }

        Integer applied = OrdersProjection.apply(
            delivery.accountId,
            delivery.accountFriendlyId,
            new List<OrdersProjection.Change>{delivery.change}
        );
        if (applied == 0) {
            receipt.Outcome__c = 'IgnoredStale';
            update as user receipt;
        }
        return new Result(receipt.Outcome__c, null);
    }

    public static Result recordOutcome(Delivery delivery, String outcome, String reason) {
        Boolean inserted = claim(buildReceipt(delivery, outcome, reason));
        return inserted ? new Result(outcome, reason) : new Result('Duplicate', null);
    }

    private static Orders_Event__c buildReceipt(Delivery delivery, String outcome, String reason) {
        return new Orders_Event__c(
            External_Id__c = delivery.eventId,
            Rejected_Body_Digest__c = delivery.bodyDigest,
            Subscription_Id__c = delivery.subscriptionId,
            Account_External_Id__c = delivery.accountId,
            Order_External_Id__c = delivery.orderId,
            Event_Type__c = delivery.eventType,
            Occurred_At__c = delivery.occurredAt,
            Outcome__c = outcome,
            Reason__c = reason
        );
    }

    private static Boolean claim(Orders_Event__c receipt) {
        try {
            // Only a unique-key failure on the receipt means this delivery was already resolved.
            insert as user receipt;
        } catch (DmlException ex) {
            if ('DUPLICATE_VALUE'.equals(ex.getDmlStatusCode(0))) {
                return false;
            }
            throw ex;
        }
        return true;
    }
}
