// Run only in a personal Developer Edition using the public take-home fixtures.
Organization environment = [SELECT OrganizationType, IsSandbox FROM Organization LIMIT 1];
Assert.isTrue(environment.OrganizationType == 'Developer Edition' && !environment.IsSandbox,
    'Use your personal Developer Edition for this exercise.');

String fixtureSecret = 'orders-takehome-2026';
String fixtureSubscription = 'sub_a1b2c3d4e5f67890abcdef12';
Orders_Settings__c settings = Orders_Settings__c.getOrgDefaults();
if (settings == null || settings.Id == null) {
    insert new Orders_Settings__c(
        SetupOwnerId = UserInfo.getOrganizationId(),
        Webhook_Secret__c = fixtureSecret,
        Expected_Subscription_Id__c = fixtureSubscription
    );
} else {
    Assert.isTrue(String.isBlank(settings.Webhook_Secret__c) || fixtureSecret.equals(settings.Webhook_Secret__c),
        'Existing signing configuration was preserved.');
    Assert.isTrue(String.isBlank(settings.Expected_Subscription_Id__c)
        || fixtureSubscription.equals(settings.Expected_Subscription_Id__c),
        'Existing subscription configuration was preserved.');
    if (String.isBlank(settings.Webhook_Secret__c) || String.isBlank(settings.Expected_Subscription_Id__c)) {
        settings.Webhook_Secret__c = fixtureSecret;
        settings.Expected_Subscription_Id__c = fixtureSubscription;
        update settings;
    }
}

String externalId = 'acct_8f3c2a';
List<Account> linked = [SELECT Id FROM Account WHERE Orders_External_Id__c = :externalId];
if (linked.isEmpty()) {
    insert new Account(Name = 'Northwind Plan Sponsor LLC', Orders_External_Id__c = externalId);
}
