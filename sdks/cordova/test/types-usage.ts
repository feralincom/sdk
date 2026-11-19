// Tip bildirimlerinin derleme denetimi (yalnız `tsc --noEmit`; çalıştırılmaz).
import type { DeferredDeepLink, FeralinConfig, FeralinCordova, RevenueInput } from "../types/index";

declare const feralin: FeralinCordova;

const config: FeralinConfig = {
  projectKey: "pk_test_123456",
  collectUrl: "https://collect.example.com",
  consent: { analytics: true, advertising: false },
  attribution: { apiUrl: "https://api.example.com", projectId: "prj_1" },
};

const revenue: RevenueInput = { transactionId: "order_1", amountMinor: 4999, currency: "TRY", purchaseType: "purchase" };

export async function usage(): Promise<void> {
  const ready: boolean = await feralin.initialize(config);
  if (!ready) return;
  const id: string | null = await feralin.track("level_up", { level: 3 });
  await feralin.trackRevenue(revenue);
  const first = await feralin.trackFirstOpen();
  const status: "sent" | "automatic" | "already_sent" | "skipped" | "not_initialized" = first.status;
  await feralin.consumeDeferredDeepLink((link: DeferredDeepLink) => link.path);
  const skip: boolean = feralin.isUninstallCheck({ fr_uninstall_check: "1" });
  const fromWindow: FeralinCordova = window.Feralin;
  void [id, status, skip, fromWindow];
}
