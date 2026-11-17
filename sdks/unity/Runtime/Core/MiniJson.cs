using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Feralin.Unity
{
    /// <summary>
    /// Bağımlılıksız JSON yazıcı ve okuyucu. Unity'de System.Text.Json yoktur, JsonUtility sözlük yazamaz; Newtonsoft
    /// paketi zorunlu bağımlılık olmasın diye yalnız SDK'nın gereksindiği kadarı burada.
    /// </summary>
    internal static class MiniJson
    {
        private const int MaxDepth = 16;

        public static string Write(object value)
        {
            var builder = new StringBuilder(256);
            WriteValue(builder, value, 0);
            return builder.ToString();
        }

        private static void WriteValue(StringBuilder b, object value, int depth)
        {
            if (depth > MaxDepth)
            {
                throw new FormatException("JSON derinlik sınırı aşıldı");
            }
            switch (value)
            {
                case null:
                    b.Append("null");
                    return;
                case string text:
                    WriteString(b, text);
                    return;
                case bool flag:
                    b.Append(flag ? "true" : "false");
                    return;
                case byte _:
                case sbyte _:
                case short _:
                case ushort _:
                case int _:
                case uint _:
                case long _:
                case ulong _:
                case decimal _:
                    b.Append(((IFormattable)value).ToString(null, CultureInfo.InvariantCulture));
                    return;
                case float single:
                    WriteDouble(b, single, single.ToString("R", CultureInfo.InvariantCulture));
                    return;
                case double number:
                    WriteDouble(b, number, number.ToString("R", CultureInfo.InvariantCulture));
                    return;
                case Enum member:
                    WriteString(b, member.ToString());
                    return;
                case DateTimeOffset moment:
                    WriteString(b, FormatTime(moment));
                    return;
                case DateTime time:
                    WriteString(b, FormatTime(new DateTimeOffset(time)));
                    return;
                case IDictionary map:
                    b.Append('{');
                    var firstEntry = true;
                    foreach (DictionaryEntry entry in map)
                    {
                        if (!(entry.Key is string key))
                        {
                            throw new FormatException("JSON anahtarı metin olmalı");
                        }
                        if (!firstEntry)
                        {
                            b.Append(',');
                        }
                        firstEntry = false;
                        WriteString(b, key);
                        b.Append(':');
                        WriteValue(b, entry.Value, depth + 1);
                    }
                    b.Append('}');
                    return;
                case IEnumerable list:
                    b.Append('[');
                    var firstItem = true;
                    foreach (var item in list)
                    {
                        if (!firstItem)
                        {
                            b.Append(',');
                        }
                        firstItem = false;
                        WriteValue(b, item, depth + 1);
                    }
                    b.Append(']');
                    return;
                default:
                    throw new FormatException("JSON'a dönüştürülemeyen tür: " + value.GetType().Name);
            }
        }

        private static void WriteDouble(StringBuilder b, double value, string text)
        {
            if (double.IsNaN(value) || double.IsInfinity(value))
            {
                throw new FormatException("NaN veya sonsuz sayı JSON'a yazılamaz");
            }
            b.Append(text);
        }

        public static string FormatTime(DateTimeOffset value) =>
            value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

        private static void WriteString(StringBuilder b, string text)
        {
            b.Append('"');
            foreach (var ch in text)
            {
                switch (ch)
                {
                    case '"':
                        b.Append("\\\"");
                        break;
                    case '\\':
                        b.Append("\\\\");
                        break;
                    case '\n':
                        b.Append("\\n");
                        break;
                    case '\r':
                        b.Append("\\r");
                        break;
                    case '\t':
                        b.Append("\\t");
                        break;
                    default:
                        if (ch < 0x20)
                        {
                            b.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            b.Append(ch);
                        }
                        break;
                }
            }
            b.Append('"');
        }

        /// <summary>JSON ayrıştırır: nesne → Dictionary, dizi → List, sayı → double. Geçersiz metinde FormatException.</summary>
        public static object Parse(string text)
        {
            var position = 0;
            var value = ParseValue(text, ref position, 0);
            SkipSpace(text, ref position);
            if (position != text.Length)
            {
                throw new FormatException("JSON sonunda fazla karakter");
            }
            return value;
        }

        private static object ParseValue(string s, ref int i, int depth)
        {
            if (depth > MaxDepth)
            {
                throw new FormatException("JSON derinlik sınırı aşıldı");
            }
            SkipSpace(s, ref i);
            if (i >= s.Length)
            {
                throw new FormatException("JSON beklenmedik sonlandı");
            }
            switch (s[i])
            {
                case '{':
                    return ParseObject(s, ref i, depth);
                case '[':
                    return ParseArray(s, ref i, depth);
                case '"':
                    return ParseString(s, ref i);
                case 't':
                    return Literal(s, ref i, "true", true);
                case 'f':
                    return Literal(s, ref i, "false", false);
                case 'n':
                    return Literal(s, ref i, "null", null);
                default:
                    return ParseNumber(s, ref i);
            }
        }

        private static object ParseObject(string s, ref int i, int depth)
        {
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            i++;
            SkipSpace(s, ref i);
            if (i < s.Length && s[i] == '}')
            {
                i++;
                return result;
            }
            while (true)
            {
                SkipSpace(s, ref i);
                if (i >= s.Length || s[i] != '"')
                {
                    throw new FormatException("JSON anahtarı bekleniyordu");
                }
                var key = ParseString(s, ref i);
                SkipSpace(s, ref i);
                if (i >= s.Length || s[i] != ':')
                {
                    throw new FormatException("JSON iki nokta bekleniyordu");
                }
                i++;
                result[key] = ParseValue(s, ref i, depth + 1);
                SkipSpace(s, ref i);
                if (i < s.Length && s[i] == ',')
                {
                    i++;
                    continue;
                }
                if (i < s.Length && s[i] == '}')
                {
                    i++;
                    return result;
                }
                throw new FormatException("JSON nesnesi kapanmadı");
            }
        }

        private static object ParseArray(string s, ref int i, int depth)
        {
            var result = new List<object>();
            i++;
            SkipSpace(s, ref i);
            if (i < s.Length && s[i] == ']')
            {
                i++;
                return result;
            }
            while (true)
            {
                result.Add(ParseValue(s, ref i, depth + 1));
                SkipSpace(s, ref i);
                if (i < s.Length && s[i] == ',')
                {
                    i++;
                    continue;
                }
                if (i < s.Length && s[i] == ']')
                {
                    i++;
                    return result;
                }
                throw new FormatException("JSON dizisi kapanmadı");
            }
        }

        private static string ParseString(string s, ref int i)
        {
            var b = new StringBuilder();
            i++;
            while (i < s.Length)
            {
                var ch = s[i++];
                if (ch == '"')
                {
                    return b.ToString();
                }
                if (ch != '\\')
                {
                    b.Append(ch);
                    continue;
                }
                if (i >= s.Length)
                {
                    break;
                }
                var escape = s[i++];
                switch (escape)
                {
                    case '"':
                    case '\\':
                    case '/':
                        b.Append(escape);
                        break;
                    case 'b':
                        b.Append('\b');
                        break;
                    case 'f':
                        b.Append('\f');
                        break;
                    case 'n':
                        b.Append('\n');
                        break;
                    case 'r':
                        b.Append('\r');
                        break;
                    case 't':
                        b.Append('\t');
                        break;
                    case 'u':
                        if (i + 4 > s.Length || !int.TryParse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var code))
                        {
                            throw new FormatException("JSON \\u kaçışı geçersiz");
                        }
                        b.Append((char)code);
                        i += 4;
                        break;
                    default:
                        throw new FormatException("JSON kaçışı geçersiz");
                }
            }
            throw new FormatException("JSON metni kapanmadı");
        }

        private static object ParseNumber(string s, ref int i)
        {
            var start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0)
            {
                i++;
            }
            if (start == i || !double.TryParse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
            {
                throw new FormatException("JSON sayısı geçersiz");
            }
            return value;
        }

        private static object Literal(string s, ref int i, string word, object value)
        {
            if (string.CompareOrdinal(s, i, word, 0, word.Length) != 0)
            {
                throw new FormatException("JSON değeri geçersiz");
            }
            i += word.Length;
            return value;
        }

        private static void SkipSpace(string s, ref int i)
        {
            while (i < s.Length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t'))
            {
                i++;
            }
        }
    }
}
