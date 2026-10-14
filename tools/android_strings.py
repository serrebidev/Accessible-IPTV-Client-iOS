"""Builds Resources/<lang>.lproj/{Localizable.strings, Localizable.stringsdict, InfoPlist.strings}
from the Android app's 14 strings.xml files, plus the iOS-only strings below.

    python tools/android_strings.py [path/to/android/app/src/main/res]

Run it after the Android translations change; commit the result. Fails on a missing
translation of an iOS-only string, so a new string needs all 14 languages at once.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RES = ROOT.parent / "accessible IPTV client Android" / "app" / "src" / "main" / "res"
OUT = ROOT / "Resources"

# Android values-<x> folder suffix -> iOS .lproj name.
LANGS = {"": "en", "ar": "ar", "de": "de", "es": "es", "fr": "fr", "hi": "hi", "hu": "hu", "it": "it",
         "ja": "ja", "pl": "pl", "pt-rBR": "pt-BR", "ru": "ru", "tr": "tr", "zh-rCN": "zh-Hans"}

# Strings the iOS app adds: system buttons Android takes from the OS, provider labels the
# Android app leaves in English, and iOS-only features. Order: en ar de es fr hi hu it ja pl pt-BR ru tr zh-Hans.
ORDER = ["en", "ar", "de", "es", "fr", "hi", "hu", "it", "ja", "pl", "pt-BR", "ru", "tr", "zh-Hans"]
EXTRA = {
    "cancel": ["Cancel", "إلغاء", "Abbrechen", "Cancelar", "Annuler", "रद्द करें", "Mégse", "Annulla", "キャンセル", "Anuluj", "Cancelar", "Отмена", "İptal", "取消"],
    "ok": ["OK", "حسنًا", "OK", "Aceptar", "OK", "ठीक है", "OK", "OK", "OK", "OK", "OK", "ОК", "Tamam", "好"],
    "clear": ["Clear", "مسح", "Löschen", "Borrar", "Effacer", "साफ़ करें", "Törlés", "Cancella", "クリア", "Wyczyść", "Limpar", "Очистить", "Temizle", "清除"],
    "cast_none": ["No cast devices found.", "لم يُعثر على أجهزة للبث.", "Keine Geräte zum Streamen gefunden.", "No se encontraron dispositivos para enviar.",
                  "Aucun appareil pour caster.", "कास्ट के लिए कोई डिवाइस नहीं मिला।", "Nem található eszköz az átküldéshez.", "Nessun dispositivo per trasmettere.",
                  "キャスト先が見つかりません。", "Nie znaleziono urządzeń do przesyłania.", "Nenhum dispositivo para transmitir.", "Устройства для трансляции не найдены.",
                  "Yayınlanacak cihaz bulunamadı.", "未找到投屏设备。"],
    "subtitle_file": ["Subtitle file", "ملف ترجمة", "Untertiteldatei", "Archivo de subtítulos", "Fichier de sous-titres", "उपशीर्षक फ़ाइल", "Feliratfájl",
                      "File di sottotitoli", "字幕ファイル", "Plik napisów", "Arquivo de legendas", "Файл субтитров", "Altyazı dosyası", "字幕文件"],
    "subtitle_speech_needs_text": ["Speech needs an SRT or WebVTT file.", "النطق يحتاج ملف SRT أو WebVTT.", "Sprachausgabe braucht eine SRT- oder WebVTT-Datei.",
                                   "La lectura necesita un archivo SRT o WebVTT.", "La lecture vocale nécessite un fichier SRT ou WebVTT.",
                                   "बोलने के लिए SRT या WebVTT फ़ाइल चाहिए।", "A felolvasáshoz SRT vagy WebVTT fájl kell.", "La lettura richiede un file SRT o WebVTT.",
                                   "読み上げには SRT か WebVTT ファイルが必要です。", "Czytanie wymaga pliku SRT lub WebVTT.", "A leitura precisa de um arquivo SRT ou WebVTT.",
                                   "Для озвучивания нужен файл SRT или WebVTT.", "Seslendirme için SRT veya WebVTT dosyası gerekir.", "朗读需要 SRT 或 WebVTT 文件。"],
    "record_open_app": ["Open the app to record %1$@.", "افتح التطبيق لتسجيل %1$@.", "App öffnen, um %1$@ aufzunehmen.", "Abre la app para grabar %1$@.",
                        "Ouvrez l’app pour enregistrer %1$@.", "%1$@ रिकॉर्ड करने के लिए ऐप खोलें।", "Nyissa meg az alkalmazást %1$@ rögzítéséhez.",
                        "Apri l’app per registrare %1$@.", "%1$@ を録画するにはアプリを開いてください。", "Otwórz aplikację, aby nagrać %1$@.",
                        "Abra o app para gravar %1$@.", "Откройте приложение, чтобы записать %1$@.", "%1$@ kaydı için uygulamayı açın.", "打开应用以录制 %1$@。"],
    "season_episode": ["Season %1$@, Episode %2$@", "الموسم %1$@، الحلقة %2$@", "Staffel %1$@, Folge %2$@", "Temporada %1$@, episodio %2$@",
                       "Saison %1$@, épisode %2$@", "सीज़न %1$@, एपिसोड %2$@", "%1$@. évad, %2$@. rész", "Stagione %1$@, episodio %2$@",
                       "シーズン %1$@、エピソード %2$@", "Sezon %1$@, odcinek %2$@", "Temporada %1$@, episódio %2$@", "Сезон %1$@, серия %2$@",
                       "Sezon %1$@, bölüm %2$@", "第 %1$@ 季，第 %2$@ 集"],
    "account_status": ["Status", "الحالة", "Status", "Estado", "Statut", "स्थिति", "Állapot", "Stato", "状態", "Stan", "Status", "Статус", "Durum", "状态"],
    "account_expires": ["Expires", "ينتهي", "Läuft ab", "Caduca", "Expire", "समाप्ति", "Lejár", "Scade", "有効期限", "Wygasa", "Expira", "Истекает", "Bitiş", "到期"],
    "account_expired_on": ["%1$@, expired", "%1$@، منتهٍ", "%1$@, abgelaufen", "%1$@, caducada", "%1$@, expiré", "%1$@, समाप्त", "%1$@, lejárt",
                           "%1$@, scaduto", "%1$@、期限切れ", "%1$@, wygasło", "%1$@, expirado", "%1$@, истекло", "%1$@, süresi doldu", "%1$@，已过期"],
    "account_days_left": ["%1$@, days left: %2$ld", "%1$@، الأيام المتبقية: %2$ld", "%1$@, verbleibende Tage: %2$ld", "%1$@, días restantes: %2$ld",
                          "%1$@, jours restants : %2$ld", "%1$@, बचे दिन: %2$ld", "%1$@, hátralévő napok: %2$ld", "%1$@, giorni rimasti: %2$ld",
                          "%1$@、残り日数: %2$ld", "%1$@, pozostało dni: %2$ld", "%1$@, dias restantes: %2$ld", "%1$@, осталось дней: %2$ld",
                          "%1$@, kalan gün: %2$ld", "%1$@，剩余天数：%2$ld"],
    "account_never": ["Never", "أبدًا", "Nie", "Nunca", "Jamais", "कभी नहीं", "Soha", "Mai", "なし", "Nigdy", "Nunca", "Никогда", "Hiçbir zaman", "永不"],
    "account_trial": ["Trial", "تجريبي", "Testzugang", "Prueba", "Essai", "ट्रायल", "Próbaidő", "Prova", "試用", "Próbny", "Teste", "Пробный", "Deneme", "试用"],
    "yes": ["Yes", "نعم", "Ja", "Sí", "Oui", "हाँ", "Igen", "Sì", "はい", "Tak", "Sim", "Да", "Evet", "是"],
    "no": ["No", "لا", "Nein", "No", "Non", "नहीं", "Nem", "No", "いいえ", "Nie", "Não", "Нет", "Hayır", "否"],
    "account_connections": ["Connections in use", "الاتصالات المستخدمة", "Verbindungen in Gebrauch", "Conexiones en uso", "Connexions utilisées",
                            "उपयोग में कनेक्शन", "Használt kapcsolatok", "Connessioni in uso", "使用中の接続", "Używane połączenia", "Conexões em uso",
                            "Используется подключений", "Kullanılan bağlantılar", "正在使用的连接"],
    "n_of_m": ["%1$@ of %2$@", "%1$@ من %2$@", "%1$@ von %2$@", "%1$@ de %2$@", "%1$@ sur %2$@", "%2$@ में से %1$@", "%1$@ / %2$@", "%1$@ di %2$@",
               "%2$@ 中 %1$@", "%1$@ z %2$@", "%1$@ de %2$@", "%1$@ из %2$@", "%2$@ içinde %1$@", "%1$@ / %2$@"],
    "account_created": ["Created", "أُنشئ", "Erstellt", "Creada", "Créé", "बनाया गया", "Létrehozva", "Creato", "作成日", "Utworzono", "Criado", "Создан", "Oluşturulma", "创建时间"],
    "account_plan": ["Plan", "الباقة", "Tarif", "Plan", "Forfait", "प्लान", "Csomag", "Piano", "プラン", "Plan", "Plano", "Тариф", "Paket", "套餐"],
    "account_balance": ["Balance", "الرصيد", "Guthaben", "Saldo", "Solde", "बैलेंस", "Egyenleg", "Saldo", "残高", "Saldo", "Saldo", "Баланс", "Bakiye", "余额"],
    "account_name": ["Name", "الاسم", "Name", "Nombre", "Nom", "नाम", "Név", "Nome", "名前", "Nazwa", "Nome", "Имя", "Ad", "名称"],
    "programme_times": ["%1$@, %2$@ to %3$@", "%1$@، من %2$@ إلى %3$@", "%1$@, %2$@ bis %3$@", "%1$@, de %2$@ a %3$@", "%1$@, de %2$@ à %3$@",
                        "%1$@, %2$@ से %3$@ तक", "%1$@, %2$@–%3$@", "%1$@, dalle %2$@ alle %3$@", "%1$@、%2$@〜%3$@", "%1$@, %2$@ do %3$@",
                        "%1$@, das %2$@ às %3$@", "%1$@, с %2$@ до %3$@", "%1$@, %2$@ - %3$@", "%1$@，%2$@ 至 %3$@"],
    "playlist_removed": ["Playlist removed", "أُزيلت القائمة", "Liste entfernt", "Lista eliminada", "Liste supprimée", "प्लेलिस्ट हटाई गई", "Lejátszási lista eltávolítva",
                         "Lista rimossa", "プレイリストが削除されました", "Lista usunięta", "Lista removida", "Плейлист удалён", "Liste kaldırıldı", "播放列表已删除"],
    "not_settings_file": ["Not a settings file", "ليس ملف إعدادات", "Keine Einstellungsdatei", "No es un archivo de ajustes", "Ce n’est pas un fichier de réglages",
                          "यह सेटिंग फ़ाइल नहीं है", "Nem beállításfájl", "Non è un file di impostazioni", "設定ファイルではありません", "To nie jest plik ustawień",
                          "Não é um arquivo de configurações", "Это не файл настроек", "Ayar dosyası değil", "不是设置文件"],
}

# Privacy texts iOS shows when it asks for permission.
INFOPLIST = {
    "NSLocalNetworkUsageDescription": ["Finds Chromecast devices to cast to.", "يبحث عن أجهزة Chromecast للبث إليها.", "Sucht Chromecast-Geräte zum Streamen.",
                                       "Busca dispositivos Chromecast a los que enviar.", "Recherche les appareils Chromecast vers lesquels caster.",
                                       "कास्ट करने के लिए Chromecast डिवाइस खोजता है।", "Chromecast-eszközöket keres az átküldéshez.",
                                       "Cerca dispositivi Chromecast su cui trasmettere.", "キャスト先の Chromecast デバイスを探します。",
                                       "Wyszukuje urządzenia Chromecast do przesyłania.", "Procura dispositivos Chromecast para transmitir.",
                                       "Ищет устройства Chromecast для трансляции.", "Yayın için Chromecast cihazlarını bulur.", "查找可投屏的 Chromecast 设备。"],
    "NSMicrophoneUsageDescription": ["Voice search listens for a channel name.", "يستمع البحث الصوتي إلى اسم القناة.", "Die Sprachsuche hört auf einen Sendernamen.",
                                     "La búsqueda por voz escucha el nombre de un canal.", "La recherche vocale écoute un nom de chaîne.",
                                     "वॉइस खोज चैनल का नाम सुनती है।", "A hangalapú keresés egy csatornanevet hallgat.", "La ricerca vocale ascolta il nome di un canale.",
                                     "音声検索でチャンネル名を聞き取ります。", "Wyszukiwanie głosowe słucha nazwy kanału.", "A busca por voz ouve o nome de um canal.",
                                     "Голосовой поиск слушает название канала.", "Sesli arama bir kanal adını dinler.", "语音搜索会聆听频道名称。"],
    "NSSpeechRecognitionUsageDescription": ["Voice search turns what you say into a search.", "يحوّل البحث الصوتي ما تقوله إلى بحث.",
                                            "Die Sprachsuche macht aus dem Gesagten eine Suche.", "La búsqueda por voz convierte lo que dices en una búsqueda.",
                                            "La recherche vocale transforme vos paroles en recherche.", "वॉइस खोज आपकी बात को खोज में बदलती है।",
                                            "A hangalapú keresés a kimondott szöveget keresésre alakítja.", "La ricerca vocale trasforma ciò che dici in una ricerca.",
                                            "音声検索は話した内容を検索に変換します。", "Wyszukiwanie głosowe zamienia mowę na wyszukiwanie.",
                                            "A busca por voz transforma o que você diz em uma busca.", "Голосовой поиск превращает сказанное в поисковый запрос.",
                                            "Sesli arama söylediğinizi aramaya çevirir.", "语音搜索会将你说的话转为搜索。"],
}


def android_text(raw):
    """Android resource escapes to plain text: \\' \\" \\n \\@ \\?, and a "quoted" whole value."""
    s = raw or ""
    if len(s) >= 2 and s[0] == s[-1] == '"':
        s = s[1:-1]
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def ios_format(s):
    """Java format specifiers to Cocoa: %1$s -> %1$@, %s -> %@, %d -> %ld."""
    s = re.sub(r"%(\d+)\$s", r"%\1$@", s)
    s = re.sub(r"%(\d+)\$d", r"%\1$ld", s)
    s = re.sub(r"%s", "%@", s)
    return re.sub(r"%d", "%ld", s)


def read(res, suffix):
    path = res / (f"values-{suffix}" if suffix else "values") / "strings.xml"
    root = ET.parse(path).getroot()
    strings, plurals, untranslatable = {}, {}, set()
    for el in root:
        name = el.get("name")
        if el.tag == "string":
            strings[name] = ios_format(android_text("".join(el.itertext())))
            if el.get("translatable") == "false":
                untranslatable.add(name)
        elif el.tag == "plurals":
            plurals[name] = {i.get("quantity"): ios_format(android_text("".join(i.itertext()))) for i in el.findall("item")}
    return strings, plurals, untranslatable


def strings_file(d):
    def q(v):
        return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return "".join(f'"{q(k)}" = "{q(v)}";\n' for k, v in sorted(d.items()))


def stringsdict(plurals):
    parts = ['<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n']
    for name, forms in sorted(plurals.items()):
        parts.append(f"\t<key>{name}</key>\n\t<dict>\n\t\t<key>NSStringLocalizedFormatKey</key>\n\t\t<string>%#@n@</string>\n\t\t<key>n</key>\n\t\t<dict>\n")
        parts.append("\t\t\t<key>NSStringFormatSpecTypeKey</key>\n\t\t\t<string>NSStringPluralRuleType</string>\n\t\t\t<key>NSStringFormatValueTypeKey</key>\n\t\t\t<string>ld</string>\n")
        for q in ["zero", "one", "two", "few", "many", "other"]:
            if q in forms:
                parts.append(f"\t\t\t<key>{q}</key>\n\t\t\t<string>{escape(forms[q])}</string>\n")
        parts.append("\t\t</dict>\n\t</dict>\n")
    parts.append("</dict>\n</plist>\n")
    return "".join(parts)


def main():
    res = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RES
    base, base_plurals, untranslatable = read(res, "")
    for key, values in {**EXTRA, **INFOPLIST}.items():
        if len(values) != len(ORDER):
            sys.exit(f"{key}: {len(values)} translations, need {len(ORDER)}")
    for suffix, lang in LANGS.items():
        strings, plurals, _ = read(res, suffix) if suffix else (base, base_plurals, set())
        merged = dict(base)  # English fills any gap, and the untranslatable strings
        merged.update({k: v for k, v in strings.items() if k not in untranslatable})
        for key, values in EXTRA.items():
            merged[key] = values[ORDER.index(lang)]
        merged_plurals = dict(base_plurals)
        merged_plurals.update(plurals)
        d = OUT / f"{lang}.lproj"
        d.mkdir(parents=True, exist_ok=True)
        (d / "Localizable.strings").write_text(strings_file(merged), encoding="utf-8", newline="\n")
        (d / "Localizable.stringsdict").write_text(stringsdict(merged_plurals), encoding="utf-8", newline="\n")
        info = {k: v[ORDER.index(lang)] for k, v in INFOPLIST.items()}
        info["CFBundleDisplayName"] = "Accessible IPTV"
        (d / "InfoPlist.strings").write_text(strings_file(info), encoding="utf-8", newline="\n")
        missing = [k for k in base if k not in strings and k not in untranslatable] if suffix else []
        print(f"{lang}: {len(merged)} strings, {len(merged_plurals)} plurals" + (f", English fallback for {missing}" if missing else ""))


if __name__ == "__main__":
    main()
