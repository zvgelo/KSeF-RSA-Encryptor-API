import { TFontDictionary } from 'pdfmake/interfaces';
export interface FontConfig {
    vfs?: Record<string, Base64URLString>;
    fonts?: TFontDictionary;
}
export declare function configureFonts(fontConfig: FontConfig): void;
export declare function getDefaultFontName(): string | undefined;
