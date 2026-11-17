// react-native eş bağımlılıktır ve bu depoya kurulmaz (kilit dosyası yüzlerce paket büyümesin); yalnız kullanılan yüzey tiplenir.
declare module "react-native" {
  export const NativeModules: Record<string, unknown>;
  export const Platform: { OS: string };
}

// Metro paketleyicisinin `require` işlevi; Node tipleri bu pakete eklenmez.
declare function require(id: "promise/setimmediate/rejection-tracking"): {
  enable(options: { allRejections: boolean; onUnhandled: (id: unknown, reason: unknown) => void }): void;
};
