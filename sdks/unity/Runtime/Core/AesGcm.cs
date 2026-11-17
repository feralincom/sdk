using System;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;

// Çekirdek birim testleri (dotnet test) iç yardımcıları doğrudan sınar.
[assembly: InternalsVisibleTo("Feralin.Unity.Core.Tests")]

namespace Feralin.Unity
{
    /// <summary>
    /// Yönetilen AES-GCM (NIST SP 800-38D, 96 bit IV, 128 bit etiket). Unity'nin Mono/IL2CPP profilinde <c>AesGcm</c> sınıfı bulunmadığı
    /// için yalnız <see cref="Aes"/> blok şifresi üstüne yazıldı; WebGL dahil her hedefte aynı çalışır. Olay gövdeleri küçüktür,
    /// bu yüzden bit düzeyinde GHASH hızı yeterlidir. Testler .NET'in <c>AesGcm</c> sınıfı ve NIST vektörleriyle karşılaştırır.
    /// </summary>
    internal static class ManagedAesGcm
    {
        public const int IvBytes = 12;
        public const int TagBytes = 16;

        /// <summary>Şifreler; çıktı <c>şifreli metin ‖ etiket</c>.</summary>
        public static byte[] Seal(byte[] key, byte[] iv, byte[] plain, byte[] aad)
        {
            Validate(key, iv);
            using (var aes = NewAes(key))
            using (var encryptor = aes.CreateEncryptor())
            {
                var h = EncryptBlock(encryptor, new byte[16]);
                var j0 = CounterBlock(iv, 1);
                var output = new byte[plain.Length + TagBytes];
                Ctr(encryptor, iv, plain, output, 0);
                var tag = Tag(encryptor, h, j0, aad, output, plain.Length);
                Buffer.BlockCopy(tag, 0, output, plain.Length, TagBytes);
                return output;
            }
        }

        /// <summary>Çözer; etiket tutmazsa (kurcalama, yanlış anahtar, yanlış aad) <c>null</c> döner, fırlatmaz.</summary>
        public static byte[] Open(byte[] key, byte[] iv, byte[] sealedData, byte[] aad)
        {
            Validate(key, iv);
            if (sealedData == null || sealedData.Length < TagBytes)
            {
                return null;
            }
            var length = sealedData.Length - TagBytes;
            using (var aes = NewAes(key))
            using (var encryptor = aes.CreateEncryptor())
            {
                var h = EncryptBlock(encryptor, new byte[16]);
                var j0 = CounterBlock(iv, 1);
                var expected = Tag(encryptor, h, j0, aad, sealedData, length);
                var diff = 0;
                for (var i = 0; i < TagBytes; i++)
                {
                    diff |= expected[i] ^ sealedData[length + i];
                }
                if (diff != 0)
                {
                    return null;
                }
                var plain = new byte[length];
                var cipherOnly = new byte[length];
                Buffer.BlockCopy(sealedData, 0, cipherOnly, 0, length);
                Ctr(encryptor, iv, cipherOnly, plain, 0);
                return plain;
            }
        }

        private static void Validate(byte[] key, byte[] iv)
        {
            if (key == null || (key.Length != 16 && key.Length != 24 && key.Length != 32))
            {
                throw new ArgumentException("AES anahtarı 16, 24 veya 32 bayt olmalı", nameof(key));
            }
            if (iv == null || iv.Length != IvBytes)
            {
                throw new ArgumentException("IV 12 bayt olmalı", nameof(iv));
            }
        }

        private static Aes NewAes(byte[] key)
        {
            var aes = Aes.Create();
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            aes.Key = key;
            return aes;
        }

        private static byte[] EncryptBlock(ICryptoTransform encryptor, byte[] block)
        {
            var output = new byte[16];
            encryptor.TransformBlock(block, 0, 16, output, 0);
            return output;
        }

        private static byte[] CounterBlock(byte[] iv, uint counter)
        {
            var block = new byte[16];
            Buffer.BlockCopy(iv, 0, block, 0, IvBytes);
            block[12] = (byte)(counter >> 24);
            block[13] = (byte)(counter >> 16);
            block[14] = (byte)(counter >> 8);
            block[15] = (byte)counter;
            return block;
        }

        // Sayaç J0'dan sonraki bloktan (2) başlar; çıktı <paramref name="output"/> içine <paramref name="offset"/> konumundan yazılır.
        private static void Ctr(ICryptoTransform encryptor, byte[] iv, byte[] input, byte[] output, int offset)
        {
            uint counter = 2;
            for (var position = 0; position < input.Length; position += 16)
            {
                var stream = EncryptBlock(encryptor, CounterBlock(iv, counter));
                counter++;
                var count = Math.Min(16, input.Length - position);
                for (var i = 0; i < count; i++)
                {
                    output[offset + position + i] = (byte)(input[position + i] ^ stream[i]);
                }
            }
        }

        private static byte[] Tag(ICryptoTransform encryptor, byte[] h, byte[] j0, byte[] aad, byte[] cipher, int cipherLength)
        {
            ReadBlock(h, 0, 16, out var hh, out var hl);
            ulong yh = 0, yl = 0;
            Absorb(ref yh, ref yl, hh, hl, aad, aad?.Length ?? 0);
            Absorb(ref yh, ref yl, hh, hl, cipher, cipherLength);
            yh ^= (ulong)(aad?.Length ?? 0) * 8;
            yl ^= (ulong)cipherLength * 8;
            Multiply(ref yh, ref yl, hh, hl);

            var mask = EncryptBlock(encryptor, j0);
            var tag = new byte[16];
            for (var i = 0; i < 8; i++)
            {
                tag[i] = (byte)((yh >> (56 - (8 * i))) ^ mask[i]);
                tag[8 + i] = (byte)((yl >> (56 - (8 * i))) ^ mask[8 + i]);
            }
            return tag;
        }

        private static void Absorb(ref ulong yh, ref ulong yl, ulong hh, ulong hl, byte[] data, int length)
        {
            for (var position = 0; position < length; position += 16)
            {
                ReadBlock(data, position, Math.Min(16, length - position), out var bh, out var bl);
                yh ^= bh;
                yl ^= bl;
                Multiply(ref yh, ref yl, hh, hl);
            }
        }

        // Kısa blok sağdan sıfırla doldurulur (GCM dolgusu).
        private static void ReadBlock(byte[] data, int offset, int count, out ulong high, out ulong low)
        {
            high = 0;
            low = 0;
            for (var i = 0; i < 16; i++)
            {
                ulong value = i < count ? data[offset + i] : (ulong)0;
                if (i < 8)
                {
                    high |= value << (56 - (8 * i));
                }
                else
                {
                    low |= value << (56 - (8 * (i - 8)));
                }
            }
        }

        // GF(2^128) çarpımı (SP 800-38D algoritma 1): x = x · h.
        private static void Multiply(ref ulong xh, ref ulong xl, ulong hh, ulong hl)
        {
            ulong zh = 0, zl = 0, vh = hh, vl = hl;
            for (var i = 0; i < 128; i++)
            {
                var bit = i < 64 ? (xh >> (63 - i)) & 1UL : (xl >> (127 - i)) & 1UL;
                if (bit == 1UL)
                {
                    zh ^= vh;
                    zl ^= vl;
                }
                var carry = vl & 1UL;
                vl = (vl >> 1) | (vh << 63);
                vh >>= 1;
                if (carry == 1UL)
                {
                    vh ^= 0xE100000000000000UL;
                }
            }
            xh = zh;
            xl = zl;
        }
    }
}
