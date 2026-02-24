declare module "pdf-parse" {
  type PdfParseTextResult = {
    text?: string;
  };

  class PDFParse {
    constructor(options: { data?: Buffer | Uint8Array | ArrayBuffer; url?: string });
    getText(options?: Record<string, unknown>): Promise<PdfParseTextResult>;
    destroy(): Promise<void>;
  }

  export { PDFParse };
}
