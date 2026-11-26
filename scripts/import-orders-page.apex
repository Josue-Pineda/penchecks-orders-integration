// Link this Account in Salesforce and configure the Orders_API Named Credential first.
// Run a separate transaction for every page. Set this value to the previous result's nextPage.
Integer page = 1;
OrdersPageImport.Result result = OrdersPageImport.run('acct_8f3c2a', page);
System.debug(LoggingLevel.INFO, JSON.serialize(result));
