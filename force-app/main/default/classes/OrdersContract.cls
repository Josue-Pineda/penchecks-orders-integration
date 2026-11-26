public with sharing class OrdersContract {
    public class InvalidPayloadException extends Exception {}

    public static Map<String, Object> objectValue(Object value, String field) {
        if (!(value instanceof Map<String, Object>)) {
            throw new InvalidPayloadException('Expected object: ' + field);
        }
        return (Map<String, Object>) value;
    }

    public static Map<String, Object> optionalObject(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
    }

    public static String optionalText(Object value, Integer maxLength) {
        if (!(value instanceof String)) {
            return null;
        }
        String text = (String) value;
        return String.isBlank(text) || text.length() > maxLength || !text.equals(text.trim()) ? null : text;
    }

    public static String textValue(Object value, String field, Integer maxLength) {
        String text = optionalText(value, maxLength);
        if (text == null) {
            throw new InvalidPayloadException('Invalid text: ' + field);
        }
        return text;
    }

    public class Money {
        public Decimal amount { get; private set; }
        public String currencyCode { get; private set; }

        public Money(Object value, String field) {
            Map<String, Object> fields = objectValue(value, field);
            String amountText = textValue(fields.get('value'), field + '.value', 21);
            currencyCode = textValue(fields.get('currency'), field + '.currency', 3);
            if (!Pattern.matches('^-?[0-9]{1,14}(\\.[0-9]{1,4})?$', amountText)
                || !Pattern.matches('^[A-Z]{3}$', currencyCode)) {
                throw new InvalidPayloadException('Invalid monetary value: ' + field);
            }
            amount = Decimal.valueOf(amountText);
        }
    }

    public static Datetime timestamp(Object value, String field) {
        String text = textValue(value, field, 35);
        if (!Pattern.matches(
            '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,3})?(Z|[+-]\\d{2}:\\d{2})$',
            text
        )) {
            throw new InvalidPayloadException('Expected ISO-8601 timestamp: ' + field);
        }
        try {
            return (Datetime) JSON.deserialize(JSON.serialize(text), Datetime.class);
        } catch (JSONException ex) {
            throw new InvalidPayloadException('Invalid timestamp: ' + field);
        }
    }
}
