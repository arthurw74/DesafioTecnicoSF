@IsTest
private class Csvimportcontrollertest {

    @TestSetup
    static void makeData() {
        Product2 prod = new Product2(Name = 'Produto Teste', ExternalId = 'PROD-001', IsActive = true);
        insert prod;

        insert new Product2(Name = 'Inativo', ExternalId = 'PROD-INATIVO', IsActive = false);

        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100.00,
            IsActive     = true
        );

        insert new Opportunity(
            Name         = 'Opp Teste',
            StageName    = 'Prospecting',
            CloseDate    = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );

        insert new Opportunity(
            Name      = 'Opp Sem PB',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
    }

    static CsvImportController.CsvRow row(String code, Decimal qty, Decimal price) {
        CsvImportController.CsvRow r = new CsvImportController.CsvRow();
        r.externalId = code;
        r.quantity   = qty;
        r.unitPrice  = price;
        return r;
    }

    static Id oppId() {
        return [SELECT Id FROM Opportunity WHERE Name = 'Opp Teste' LIMIT 1].Id;
    }


    @IsTest static void testValidate_found() {
        List<CsvImportController.ValidationResult> res =
            CsvImportController.validateProducts(new List<String>{ 'PROD-001' });
        System.assertEquals(true, res[0].exists);
    }

    @IsTest static void testValidate_notFound() {
        List<CsvImportController.ValidationResult> res =
            CsvImportController.validateProducts(new List<String>{ 'NAO-EXISTE' });
        System.assertEquals(false, res[0].exists);
    }

    @IsTest static void testValidate_inactive() {
        List<CsvImportController.ValidationResult> res =
            CsvImportController.validateProducts(new List<String>{ 'PROD-INATIVO' });
        System.assertEquals(false, res[0].exists);
    }

    @IsTest static void testValidate_limitExceeded() {
        List<String> big = new List<String>();
        for (Integer i = 0; i < 2001; i++) big.add('X' + i);
        try {
            CsvImportController.validateProducts(big);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }


    @IsTest static void testImport_success() {
        CsvImportController.ImportResponse res =
            CsvImportController.importLineItems(oppId(), new List<CsvImportController.CsvRow>{ row('PROD-001', 2, 50) });
        System.assertEquals(true, res.success);
        System.assertEquals(1, res.inserted);
    }

    @IsTest static void testImport_idempotency() {
        Id id = oppId();
        CsvImportController.importLineItems(id, new List<CsvImportController.CsvRow>{ row('PROD-001', 1, 10) });
        try {
            CsvImportController.importLineItems(id, new List<CsvImportController.CsvRow>{ row('PROD-001', 1, 10) });
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals(1, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :id]);
    }

    @IsTest static void testImport_noPricebook() {
        Id id = [SELECT Id FROM Opportunity WHERE Name = 'Opp Sem PB' LIMIT 1].Id;
        try {
            CsvImportController.importLineItems(id, new List<CsvImportController.CsvRow>{ row('PROD-001', 1, 10) });
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest static void testImport_invalidQuantity() {
        try {
            CsvImportController.importLineItems(oppId(), new List<CsvImportController.CsvRow>{ row('PROD-001', 0, 10) });
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest static void testImport_invalidPrice() {
        try {
            CsvImportController.importLineItems(oppId(), new List<CsvImportController.CsvRow>{ row('PROD-001', 1, -1) });
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest static void testImport_emptyRows() {
        try {
            CsvImportController.importLineItems(oppId(), new List<CsvImportController.CsvRow>());
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest static void testImport_blankOppId() {
        try {
            CsvImportController.importLineItems('', new List<CsvImportController.CsvRow>{ row('PROD-001', 1, 10) });
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest static void testImport_limitExceeded() {
        List<CsvImportController.CsvRow> big = new List<CsvImportController.CsvRow>();
        for (Integer i = 0; i < 2001; i++) big.add(row('X' + i, 1, 10));
        try {
            CsvImportController.importLineItems(oppId(), big);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}