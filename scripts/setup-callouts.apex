// Sets the bearer token that the Orders_API Named Credential sends to the demo mock.
// The mock accepts any non-empty token; for a real Orders environment, enter the issued token in Setup instead.
Organization environment = [SELECT OrganizationType, IsSandbox FROM Organization LIMIT 1];
Assert.isTrue(environment.OrganizationType == 'Developer Edition' && !environment.IsSandbox,
    'Use your personal Developer Edition for this exercise.');

ConnectApi.CredentialValueInput token = new ConnectApi.CredentialValueInput();
token.value = 'orders-demo-token';
token.encrypted = true;

ConnectApi.CredentialInput input = new ConnectApi.CredentialInput();
input.externalCredential = 'Orders_API_Auth';
input.principalName = 'OrdersPrincipal';
input.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
input.authenticationProtocol = ConnectApi.CredentialAuthenticationProtocol.Custom;
input.credentials = new Map<String, ConnectApi.CredentialValueInput>{ 'Token' => token };

ConnectApi.Credential existing = ConnectApi.NamedCredentials.getCredential(
    'Orders_API_Auth', 'OrdersPrincipal', ConnectApi.CredentialPrincipalType.NamedPrincipal
);
if (existing.credentials == null || existing.credentials.isEmpty()) {
    ConnectApi.NamedCredentials.createCredential(input);
} else {
    ConnectApi.NamedCredentials.updateCredential(input);
}
System.debug(LoggingLevel.INFO, 'Orders_API_Auth token is set for principal OrdersPrincipal.');
