import { LightningElement, api, track } from 'lwc';
import validateProducts from '@salesforce/apex/CsvImportController.validateProducts';
import importLineItems  from '@salesforce/apex/CsvImportController.importLineItems';

const MAX_ROWS        = 2000;
const PAGE_SIZE       = 30;
const EXPECTED_FIELDS = ['externalid', 'quantity', 'unitprice'];
const CSV_TEMPLATE    = 'externalId,quantity,unitPrice\nEXT-001,1,99.90\nEXT-002,2,49.50\n';

const STATUS = {
    ALL:       'Todas',
    VALID:     'Valida',
    INVALID:   'Invalida',
    DUPLICATE: 'Duplicada',
};

const FILTER = {
    ALL:       'all',
    VALID:     'valid',
    INVALID:   'invalid',
    DUPLICATE: 'duplicate',
};

export default class CsvImporter extends LightningElement {

    @api recordId;

    @track previewRows    = [];
    @track structureError = null;
    @track isLoading      = false;
    @track importResult   = null;
    @track importSuccess  = false;
    @track activeFilter   = FILTER.ALL;
    @track currentPage    = 1;
    @track spinnerMessage    = 'Processando...';
    @track showSuccessModal  = false;
    @track successMessage    = '';
    _importing = false;

    get filterOptions() {
        return [
            { label: 'Todas (' + this.previewRows.length + ')', value: FILTER.ALL },
            { label: 'Validas (' + this.validCount + ')',        value: FILTER.VALID },
            { label: 'Invalidas (' + this.invalidCount + ')',    value: FILTER.INVALID },
            { label: 'Duplicadas (' + this.duplicateCount + ')', value: FILTER.DUPLICATE },
        ];
    }

    get totalCount() {
        return this.previewRows.length;
    }

    get validCount() {
        return this.previewRows.filter(r => r.status === STATUS.VALID).length;
    }

    get invalidCount() {
        return this.previewRows.filter(r => r.status === STATUS.INVALID).length;
    }

    get duplicateCount() {
        return this.previewRows.filter(r => r.status === STATUS.DUPLICATE).length;
    }

    get hasRows() {
        return this.previewRows.length > 0;
    }

    get filteredRows() {
        if (this.activeFilter === FILTER.VALID) {
            return this.previewRows.filter(r => r.status === STATUS.VALID);
        }
        if (this.activeFilter === FILTER.INVALID) {
            return this.previewRows.filter(r => r.status === STATUS.INVALID);
        }
        if (this.activeFilter === FILTER.DUPLICATE) {
            return this.previewRows.filter(r => r.status === STATUS.DUPLICATE);
        }
        return this.previewRows;
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.filteredRows.length / PAGE_SIZE));
    }

    get pagedRows() {
        const start = (this.currentPage - 1) * PAGE_SIZE;
        return this.filteredRows.slice(start, start + PAGE_SIZE);
    }

    get pageLabel() {
        return 'Pagina ' + this.currentPage + ' de ' + this.totalPages;
    }

    get paginationInfo() {
        const total = this.filteredRows.length;
        const start = Math.min((this.currentPage - 1) * PAGE_SIZE + 1, total);
        const end   = Math.min(this.currentPage * PAGE_SIZE, total);
        return total === 0
            ? 'Nenhum resultado'
            : 'Exibindo ' + start + '-' + end + ' de ' + total + ' linhas';
    }

    get isFirstPage() {
        return this.currentPage === 1;
    }

    get isLastPage() {
        return this.currentPage >= this.totalPages;
    }

    get counterAllClass() {
        return this._counterClass(FILTER.ALL);
    }
    get counterValidClass() {
        return this._counterClass(FILTER.VALID);
    }
    get counterInvalidClass() {
        return this._counterClass(FILTER.INVALID);
    }
    get counterDupClass() {
        return this._counterClass(FILTER.DUPLICATE);
    }

    _counterClass(filter) {
        const base = 'slds-box slds-text-align_center';
        return this.activeFilter === filter
            ? base + ' slds-theme_shade'
            : base;
    }

    get importDisabled() {
        return (
            this.isLoading        ||
            this._importing       ||
            this.validCount === 0 ||
            this.invalidCount > 0 ||
            this.duplicateCount > 0
        );
    }

    get importButtonLabel() {
        return this.isLoading
            ? 'Importando...'
            : 'Importar (' + this.validCount + ')';
    }

    get importResultClass() {
        const base = 'slds-notify slds-notify_alert slds-m-top_small';
        return this.importSuccess
            ? base + ' slds-alert_success'
            : base + ' slds-alert_error';
    }

    filterAll() {
        this._setFilter(FILTER.ALL);
    }
    filterValid() {
        this._setFilter(FILTER.VALID);
    }
    filterInvalid() {
        this._setFilter(FILTER.INVALID);
    }
    filterDuplicate() {
        this._setFilter(FILTER.DUPLICATE);
    }

    handleFilterChange(event) {
        this._setFilter(event.detail.value);
    }

    _setFilter(filter) {
        this.activeFilter = filter;
        this.currentPage  = 1;
    }

    goFirst() { this.currentPage = 1; }
    goLast()  { this.currentPage = this.totalPages; }

    goPrev() {
        if (this.currentPage > 1) this.currentPage -= 1;
    }

    goNext() {
        if (this.currentPage < this.totalPages) this.currentPage += 1;
    }

    downloadTemplate() {
        const encoded = 'data:text/csv;charset=utf-8,' + encodeURIComponent(CSV_TEMPLATE);
        const link = this.template.querySelector('a.download-link');
        link.href     = encoded;
        link.download = 'modelo_importacao.csv';
        link.click();
    }

    handleFileChange(event) {
        const file = event.target.files[0];
        if (!file) return;

        this.previewRows    = [];
        this.structureError = null;
        this.importResult   = null;
        this.importSuccess  = false;
        this._importing     = false;
        this.activeFilter   = FILTER.ALL;
        this.currentPage    = 1;

        const reader = new FileReader();
        reader.onload = (e) => {
            this._processCsv(e.target.result);
        };
        reader.readAsText(file, 'UTF-8');
    }

    async _processCsv(content) {
        const lines = content
            .replace(/\r\n/g, '\n')
            .replace(/\r/g, '\n')
            .split('\n')
            .filter(l => l.trim() !== '');

        if (lines.length < 2) {
            this.structureError = 'Arquivo CSV vazio ou sem dados.';
            return;
        }

        const separator  = this._detectSeparator(lines[0]);
        const headerCols = lines[0].split(separator).map(h => h.trim().toLowerCase());

        const missing = EXPECTED_FIELDS.filter(f => !headerCols.includes(f));
        if (missing.length > 0) {
            this.structureError =
                'Cabecalho invalido. Campos obrigatorios ausentes: ' + missing.join(', ');
            return;
        }

        const idxExtId = headerCols.indexOf('externalid');
        const idxQty   = headerCols.indexOf('quantity');
        const idxPrice = headerCols.indexOf('unitprice');

        const dataLines = lines.slice(1);

        if (dataLines.length > MAX_ROWS) {
            this.structureError =
                'Limite de ' + MAX_ROWS + ' linhas excedido. Arquivo contem ' +
                dataLines.length + ' linhas.';
            return;
        }

        const parsed = dataLines.map((line, index) => {
            const cols       = line.split(separator);
            const externalId = (cols[idxExtId]  || '').trim();
            const qtyRaw     = (cols[idxQty]    || '').trim();
            const priceRaw   = (cols[idxPrice]  || '').trim();

            const row = {
                key:          index,
                lineNumber:   index + 1,
                externalId:   externalId,
                quantity:     qtyRaw,
                unitPrice:    priceRaw,
                status:       STATUS.VALID,
                errorMessage: '',
                rowClass:     '',
                _qtyNum:      null,
                _priceNum:    null,
            };

            const errors = [];

            if (!externalId) {
                errors.push('externalId obrigatorio');
            }

            const qty = parseFloat(qtyRaw);
            if (isNaN(qty) || qty <= 0) {
                errors.push('quantity deve ser > 0');
            } else {
                row._qtyNum = qty;
            }

            const price = parseFloat(priceRaw);
            if (isNaN(price) || price < 0) {
                errors.push('unitPrice deve ser >= 0');
            } else {
                row._priceNum = price;
            }

            if (errors.length > 0) {
                row.status       = STATUS.INVALID;
                row.errorMessage = errors.join('; ');
            }

            return row;
        });

        const seen    = {};
        const dupKeys = new Set();

        parsed.forEach(row => {
            if (!row.externalId) return;
            if (seen[row.externalId] !== undefined) {
                dupKeys.add(row.externalId);
            } else {
                seen[row.externalId] = true;
            }
        });

        parsed.forEach(row => {
            if (dupKeys.has(row.externalId)) {
                row.status       = STATUS.DUPLICATE;
                row.errorMessage = 'externalId duplicado no arquivo';
            }
        });

        const validRows = parsed.filter(r => r.status === STATUS.VALID);
        const extIds    = validRows.map(r => r.externalId);

        if (extIds.length > 0) {
            this.isLoading = true;
            try {
                const results = await validateProducts({ externalIds: extIds });

                const resultMap = {};
                results.forEach(r => { resultMap[r.externalId] = r; });

                parsed.forEach(row => {
                    if (row.status !== STATUS.VALID) return;
                    const res = resultMap[row.externalId];
                    if (res && !res.exists) {
                        row.status       = STATUS.INVALID;
                        row.errorMessage = res.errorMessage || 'Produto nao encontrado';
                    }
                });
            } catch (err) {
                this.structureError = 'Erro ao validar produtos: ' + this._extractError(err);
                this.isLoading = false;
                return;
            } finally {
                this.isLoading = false;
            }
        }

        parsed.forEach(row => {
            if (row.status === STATUS.VALID) {
                row.rowClass = '';
            } else if (row.status === STATUS.DUPLICATE) {
                row.rowClass = 'slds-theme_warning';
            } else {
                row.rowClass = 'slds-theme_error';
            }
        });

        this.previewRows = parsed;
    }

    async handleImport() {
        if (this._importing || this.importDisabled) return;
        this._importing      = true;
        this.isLoading       = true;
        this.importResult    = null;
        this.spinnerMessage  = 'Processando importacao...';

        try {
            const rows = this.previewRows
                .filter(r => r.status === STATUS.VALID)
                .map(r => ({
                    externalId: r.externalId,
                    quantity:   r._qtyNum,
                    unitPrice:  r._priceNum,
                }));

            const response = await importLineItems({
                opportunityId: this.recordId,
                rows:          rows,
            });

            if (response.success) {
                this.importSuccess = true;
                this.successMessage   = `${response.inserted} produto(s) inserido(s) com sucesso!`;
                this.showSuccessModal = true;
                this.previewRows  = [];
                this.activeFilter = FILTER.ALL;
                this.currentPage  = 1;
            } else {
                this.importSuccess = false;
                this.importResult  = response.errorMessage || 'Erro desconhecido.';
            }
        } catch (err) {
            this.importSuccess = false;
            this.importResult  = 'Erro na importacao: ' + this._extractError(err);
        } finally {
            this.isLoading  = false;
            this._importing = false;
        }
    }

    handleSuccessClose() {
        this.showSuccessModal = false;
        window.location.reload();
    }
 

    _detectSeparator(headerLine) {
        const semicolons = (headerLine.match(/;/g) || []).length;
        const commas     = (headerLine.match(/,/g) || []).length;
        return semicolons > commas ? ';' : ',';
    }

    _extractError(err) {
        if (!err) return 'Erro desconhecido';
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}