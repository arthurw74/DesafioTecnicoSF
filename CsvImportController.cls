public with sharing class CsvImportController {

    private static final Integer MAX_ROWS = 2000;
    private static Boolean flsChecked = false;

    public class CsvRow {
        @AuraEnabled public String  externalId { get; set; }
        @AuraEnabled public Decimal quantity   { get; set; }
        @AuraEnabled public Decimal unitPrice  { get; set; }
    }

    public class ValidationResult {
        @AuraEnabled public String  externalId   { get; set; }
        @AuraEnabled public Boolean exists        { get; set; }
        @AuraEnabled public String  productId     { get; set; }
        @AuraEnabled public String  errorMessage  { get; set; }

        public ValidationResult(String extId, Boolean ex, String pid, String err) {
            this.externalId  = extId;
            this.exists      = ex;
            this.productId   = pid;
            this.errorMessage = err;
        }
    }

    public class ImportResponse {
        @AuraEnabled public Boolean success      { get; set; }
        @AuraEnabled public Integer inserted     { get; set; }
        @AuraEnabled public String  errorMessage { get; set; }

        public ImportResponse(Boolean ok, Integer ins, String err) {
            this.success      = ok;
            this.inserted     = ins;
            this.errorMessage = err;
        }
    }

    private static void checkProduct2FLS() {
        if (!Schema.sObjectType.Product2.isAccessible()) {
            throw new AuraHandledException('Sem permissao de leitura no objeto Product2.');
        }
        Map<String, Schema.SObjectField> f = Schema.sObjectType.Product2.fields.getMap();
        if (!f.get('ExternalId').getDescribe().isAccessible() ||
            !f.get('Name')      .getDescribe().isAccessible() ||
            !f.get('IsActive')  .getDescribe().isAccessible()) {
            throw new AuraHandledException('Sem permissao de leitura nos campos de Product2.');
        }
    }

    @AuraEnabled
    public static List<ValidationResult> validateProducts(List<String> externalIds) {

        checkProduct2FLS();

        List<String> safeIds = new List<String>();
        for (String eid : externalIds) {
            if (String.isNotBlank(eid) && eid.length() <= 255) {
                safeIds.add(eid.trim());
            }
        }

        if (safeIds.size() > MAX_ROWS) {
            throw new AuraHandledException('Limite de ' + MAX_ROWS + ' linhas excedido.');
        }

        List<Product2> products = [
            SELECT Id, ExternalId, Name, IsActive
            FROM   Product2
            WHERE  ExternalId IN :safeIds
            WITH   SECURITY_ENFORCED
        ];

        Map<String, Product2> productMap = new Map<String, Product2>();
        for (Product2 p : products) {
            productMap.put(p.ExternalId, p);
        }

        List<ValidationResult> results = new List<ValidationResult>();
        for (String eid : safeIds) {
            if (productMap.containsKey(eid)) {
                Product2 p = productMap.get(eid);
                if (!p.IsActive) {
                    results.add(new ValidationResult(eid, false, null, 'Produto inativo.'));
                } else {
                    results.add(new ValidationResult(eid, true, p.Id, null));
                }
            } else {
                results.add(new ValidationResult(eid, false, null, 'Produto nao encontrado.'));
            }
        }
        return results;
    }

    @AuraEnabled
    public static ImportResponse importLineItems(String opportunityId, List<CsvRow> rows) {

        if (String.isBlank(opportunityId)) {
            throw new AuraHandledException('opportunityId e obrigatorio.');
        }
        if (rows == null || rows.isEmpty()) {
            throw new AuraHandledException('Nenhuma linha para importar.');
        }
        if (rows.size() > MAX_ROWS) {
            throw new AuraHandledException('Limite de ' + MAX_ROWS + ' linhas excedido.');
        }

        if (!Schema.sObjectType.OpportunityLineItem.isCreateable()) {
            throw new AuraHandledException('Sem permissao para criar OpportunityLineItem.');
        }
        Map<String, Schema.SObjectField> oliFields =
            Schema.sObjectType.OpportunityLineItem.fields.getMap();
        for (String f : new List<String>{'OpportunityId','PricebookEntryId','Quantity','UnitPrice'}) {
            if (!oliFields.get(f).getDescribe().isCreateable()) {
                throw new AuraHandledException('Sem permissao no campo ' + f + ' de OpportunityLineItem.');
            }
        }

        Id oppId;
        try {
            oppId = (Id) opportunityId;
        } catch (Exception e) {
            throw new AuraHandledException('opportunityId invalido.');
        }

        List<Opportunity> opps = [
            SELECT Id, Pricebook2Id, Name
            FROM   Opportunity
            WHERE  Id = :oppId
            WITH   SECURITY_ENFORCED
            LIMIT  1
        ];
        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity nao encontrada.');
        }
        Opportunity opp = opps[0];
        if (opp.Pricebook2Id == null) {
            throw new AuraHandledException(
                'A Opportunity "' + opp.Name + '" nao possui um Price Book associado. ' +
                'Por Favor adicione um Price Book antes de importar os produtos.'
            );
        }

        List<String> externalIds = new List<String>();
        for (CsvRow row : rows) {
            if (String.isNotBlank(row.externalId)) {
                externalIds.add(row.externalId.trim());
            }
        }

        checkProduct2FLS();

        List<Product2> products = [
            SELECT Id, ExternalId
            FROM   Product2
            WHERE  ExternalId IN :externalIds
            AND    IsActive = true
            WITH   SECURITY_ENFORCED
        ];
        Map<String, Id> extIdToProductId = new Map<String, Id>();
        for (Product2 p : products) {
            extIdToProductId.put(p.ExternalId, p.Id);
        }

        if (!Schema.sObjectType.PricebookEntry.isAccessible()) {
            throw new AuraHandledException('Sem permissao de leitura em PricebookEntry.');
        }

        Id pricebookId  = opp.Pricebook2Id;
        Set<Id> prodIds = new Set<Id>(extIdToProductId.values());

        Id stdPbId = Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Set<Id> pbIds = new Set<Id>{ stdPbId, pricebookId };

        List<PricebookEntry> pbeList = [
            SELECT Id, Product2Id, Pricebook2Id
            FROM   PricebookEntry
            WHERE  Pricebook2Id IN :pbIds
            AND    Product2Id   IN :prodIds
            AND    IsActive     = true
            WITH   SECURITY_ENFORCED
        ];

        Map<Id, Id> productIdToPbeId = new Map<Id, Id>();
        for (PricebookEntry pbe : pbeList) {
            if (pbe.Pricebook2Id == stdPbId) {
                productIdToPbeId.put(pbe.Product2Id, pbe.Id);
            }
        }
        for (PricebookEntry pbe : pbeList) {
            if (pbe.Pricebook2Id == pricebookId) {
                productIdToPbeId.put(pbe.Product2Id, pbe.Id);
            }
        }

        Set<Id> pbeIds = new Set<Id>(productIdToPbeId.values());
        List<OpportunityLineItem> existing = [
            SELECT PricebookEntryId
            FROM   OpportunityLineItem
            WHERE  OpportunityId    = :oppId
            AND    PricebookEntryId IN :pbeIds
            WITH   SECURITY_ENFORCED
        ];
        Set<Id> existingPbeIds = new Set<Id>();
        for (OpportunityLineItem oli : existing) {
            existingPbeIds.add(oli.PricebookEntryId);
        }

        List<OpportunityLineItem> toInsert = new List<OpportunityLineItem>();
        List<String> errors = new List<String>();

        for (CsvRow row : rows) {
            if (row.quantity == null || row.quantity <= 0) {
                errors.add('"' + row.externalId + '": quantity deve ser > 0.');
                continue;
            }
            if (row.unitPrice == null || row.unitPrice < 0) {
                errors.add('"' + row.externalId + '": unitPrice deve ser >= 0.');
                continue;
            }

            String code      = row.externalId.trim();
            Id     productId = extIdToProductId.get(code);
            if (productId == null) {
                errors.add('Produto nao encontrado: ' + code);
                continue;
            }

            Id pbeId = productIdToPbeId.get(productId);
            if (pbeId == null) {
                errors.add(
                    'Produto "' + code + '" nao possui entrada no Price Book da Opportunity. ' +
                    'Adicione o produto ao Price Book antes de importar.'
                );
                continue;
            }

            if (existingPbeIds.contains(pbeId)) {
                errors.add('Produto "' + code + '" ja existe na Opportunity.');
                continue;
            }

            toInsert.add(new OpportunityLineItem(
                OpportunityId    = oppId,
                PricebookEntryId = pbeId,
                Quantity         = row.quantity,
                UnitPrice        = row.unitPrice
            ));
        }

        if (!errors.isEmpty()) {
            throw new AuraHandledException('Erros:\n' + String.join(errors, '\n'));
        }
        if (toInsert.isEmpty()) {
            return new ImportResponse(false, 0, 'Nenhum item valido para inserir.');
        }

        try {
            insert toInsert;
        } catch (DmlException e) {
            throw new AuraHandledException('Erro ao inserir: ' + e.getDmlMessage(0));
        }

        return new ImportResponse(true, toInsert.size(), null);
    }
}