package com.feralin.sdk;

/** Bir flush çağrısının toplu sonucu. */
public final class FlushResult {
    static final FlushResult EMPTY = new FlushResult(0, 0, 0, null, 0, 0, null);

    private final int sent;
    private final int accepted;
    private final int rejected;
    private final String batchId;
    private final int status;
    private final int retained;
    private final DeliveryException error;

    FlushResult(int sent, int accepted, int rejected, String batchId, int status, int retained, DeliveryException error) {
        this.sent = sent;
        this.accepted = accepted;
        this.rejected = rejected;
        this.batchId = batchId;
        this.status = status;
        this.retained = retained;
        this.error = error;
    }

    /** @return gönderilmeye çalışılan olay sayısı */
    public int sent() {
        return sent;
    }

    /** @return toplayıcının kabul ettiği olay sayısı */
    public int accepted() {
        return accepted;
    }

    /** @return reddedilen olay sayısı */
    public int rejected() {
        return rejected;
    }

    /** @return son kabul edilen batch kimliği veya null */
    public String batchId() {
        return batchId;
    }

    /** @return son HTTP durum kodu; ağ hatasında veya istek yoksa 0 */
    public int status() {
        return status;
    }

    /** @return kuyrukta kalan olay sayısı */
    public int retained() {
        return retained;
    }

    /** @return teslim hatası veya null: {@link RejectedException} olaylar atıldı, {@link TemporaryException} kuyrukta */
    public DeliveryException error() {
        return error;
    }

    /** @return teslim hatası yoksa true */
    public boolean isOk() {
        return error == null;
    }

    @Override
    public String toString() {
        return "FlushResult{sent=" + sent + ", accepted=" + accepted + ", rejected=" + rejected + ", batchId=" + batchId
                + ", status=" + status + ", retained=" + retained + ", error=" + error + "}";
    }
}
