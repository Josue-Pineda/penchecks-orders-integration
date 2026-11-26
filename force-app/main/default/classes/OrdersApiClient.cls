public with sharing class OrdersApiClient {
    public static HttpResponse get(String resource) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:Orders_API' + resource);
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(5000);
        return new Http().send(request);
    }

    public static String pathSegment(String sourceId) {
        return EncodingUtil.urlEncode(sourceId, 'UTF-8').replace('+', '%20');
    }

    public static String retryAfterSeconds(HttpResponse response) {
        String seconds = response.getHeader('Retry-After')?.trim();
        return seconds != null && Pattern.matches('^[0-9]{1,8}$', seconds) ? seconds : null;
    }
}
