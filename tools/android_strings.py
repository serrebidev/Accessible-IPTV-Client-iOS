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
    "shareplay_start": ["Start SharePlay", "بدء SharePlay", "SharePlay starten", "Iniciar SharePlay", "Démarrer SharePlay", "SharePlay शुरू करें", "SharePlay indítása", "Avvia SharePlay", "SharePlayを開始", "Rozpocznij SharePlay", "Iniciar SharePlay", "Начать SharePlay", "SharePlay’i başlat", "开始 SharePlay"],
    "shareplay_leave": ["Leave SharePlay", "مغادرة SharePlay", "SharePlay verlassen", "Salir de SharePlay", "Quitter SharePlay", "SharePlay छोड़ें", "Kilépés a SharePlayből", "Esci da SharePlay", "SharePlayから退出", "Opuść SharePlay", "Sair do SharePlay", "Выйти из SharePlay", "SharePlay’den ayrıl", "离开 SharePlay"],
    "shareplay_end": ["End for everyone", "إنهاء للجميع", "Für alle beenden", "Finalizar para todos", "Terminer pour tout le monde", "सभी के लिए समाप्त करें", "Befejezés mindenkinél", "Termina per tutti", "全員のSharePlayを終了", "Zakończ dla wszystkich", "Encerrar para todos", "Завершить для всех", "Herkes için bitir", "为所有人结束"],
    "shareplay_active": ["SharePlay active", "SharePlay نشط", "SharePlay aktiv", "SharePlay activo", "SharePlay actif", "SharePlay चालू है", "SharePlay aktív", "SharePlay attivo", "SharePlayが有効", "SharePlay aktywne", "SharePlay ativo", "SharePlay активно", "SharePlay etkin", "SharePlay 已启用"],
    "shareplay_ended": ["SharePlay ended", "انتهى SharePlay", "SharePlay beendet", "SharePlay finalizado", "SharePlay terminé", "SharePlay समाप्त हुआ", "A SharePlay véget ért", "SharePlay terminato", "SharePlayが終了しました", "SharePlay zakończone", "SharePlay encerrado", "SharePlay завершено", "SharePlay sona erdi", "SharePlay 已结束"],
    "shareplay_participants": ["SharePlay: %ld participants", "SharePlay: %ld مشاركين", "SharePlay: %ld Teilnehmende", "SharePlay: %ld participantes", "SharePlay : %ld participants", "SharePlay: %ld प्रतिभागी", "SharePlay: %ld résztvevő", "SharePlay: %ld partecipanti", "SharePlay: 参加者%ld人", "SharePlay: %ld uczestników", "SharePlay: %ld participantes", "SharePlay: участников — %ld", "SharePlay: %ld katılımcı", "SharePlay：%ld 位参与者"],
    "shareplay_loading": ["Loading shared channel…", "جارٍ تحميل القناة المشتركة…", "Geteilter Sender wird geladen…", "Cargando canal compartido…", "Chargement de la chaîne partagée…", "साझा चैनल लोड हो रहा है…", "Megosztott csatorna betöltése…", "Caricamento del canale condiviso…", "共有チャンネルを読み込み中…", "Wczytywanie udostępnionego kanału…", "Carregando canal compartilhado…", "Загрузка общего канала…", "Paylaşılan kanal yükleniyor…", "正在加载共享频道…"],
    "shareplay_missing": [
        "Shared content is missing or matches several entries in your playlist. Choose a channel or leave SharePlay.",
        "المحتوى المشترك غير موجود أو يطابق عدة عناصر في قائمتك. اختر قناة أو غادر SharePlay.",
        "Der geteilte Inhalt fehlt oder passt zu mehreren Einträgen deiner Liste. Wähle einen Sender oder verlasse SharePlay.",
        "El contenido compartido no está disponible o coincide con varias entradas de tu lista. Elige un canal o sal de SharePlay.",
        "Le contenu partagé est absent ou correspond à plusieurs éléments de votre liste. Choisissez une chaîne ou quittez SharePlay.",
        "साझा सामग्री नहीं मिली या आपकी प्लेलिस्ट में कई प्रविष्टियों से मेल खाती है। चैनल चुनें या SharePlay छोड़ें।",
        "A megosztott tartalom hiányzik, vagy a lejátszási lista több elemével egyezik. Válasszon csatornát, vagy lépjen ki a SharePlayből.",
        "Il contenuto condiviso manca o corrisponde a più voci della tua lista. Scegli un canale o esci da SharePlay.",
        "共有コンテンツが見つからないか、プレイリスト内の複数の項目に一致します。チャンネルを選ぶか、SharePlayから退出してください。",
        "Brak udostępnionego materiału lub pasuje on do kilku pozycji na liście. Wybierz kanał albo opuść SharePlay.",
        "O conteúdo compartilhado não está disponível ou corresponde a várias entradas da sua lista. Escolha um canal ou saia do SharePlay.",
        "Общий контент отсутствует или соответствует нескольким записям в вашем списке. Выберите канал или выйдите из SharePlay.",
        "Paylaşılan içerik bulunamadı veya listenizde birden fazla öğeyle eşleşiyor. Bir kanal seçin veya SharePlay’den ayrılın.",
        "共享内容缺失，或与播放列表中的多个条目匹配。请选择频道或离开 SharePlay。",
    ],
    "shareplay_unavailable": [
        "SharePlay needs a named live channel, movie, numbered series episode or catch-up programme. Local recordings, files and casting are unavailable.",
        "يتطلب SharePlay قناة مباشرة لها اسمًا أو فيلمًا أو حلقة مسلسل مرقمة أو برنامجًا من الأرشيف. التسجيلات المحلية والملفات والبث إلى أجهزة أخرى غير متاحة.",
        "SharePlay benötigt einen benannten Live-Sender, Film, eine nummerierte Serienfolge oder eine nachträglich abrufbare Sendung. Lokale Aufnahmen, Dateien und Cast sind nicht verfügbar.",
        "SharePlay necesita un canal en directo con nombre, una película, un episodio numerado o un programa en diferido. No admite grabaciones locales, archivos ni transmisión a otros dispositivos.",
        "SharePlay nécessite une chaîne en direct nommée, un film, un épisode numéroté ou une émission en rattrapage. Les enregistrements locaux, fichiers et la diffusion vers un autre appareil sont indisponibles.",
        "SharePlay के लिए नाम वाला लाइव चैनल, फ़िल्म, क्रमांकित सीरीज़ एपिसोड या कैच-अप कार्यक्रम चाहिए। स्थानीय रिकॉर्डिंग, फ़ाइलें और कास्टिंग उपलब्ध नहीं हैं।",
        "A SharePlayhez névvel rendelkező élő csatorna, film, számozott sorozatepizód vagy visszanézhető műsor szükséges. Helyi rögzítések, fájlok és átküldés nem használhatók.",
        "SharePlay richiede un canale in diretta con nome, un film, un episodio numerato o un programma in replica. Registrazioni locali, file e trasmissione ad altri dispositivi non sono disponibili.",
        "SharePlayには名前付きのライブチャンネル、映画、番号付きのシリーズエピソード、または見逃し番組が必要です。ローカル録画、ファイル、キャストは利用できません。",
        "SharePlay wymaga nazwanego kanału na żywo, filmu, numerowanego odcinka serialu lub programu z archiwum. Lokalne nagrania, pliki i przesyłanie na inne urządzenia są niedostępne.",
        "O SharePlay precisa de um canal ao vivo com nome, filme, episódio numerado de série ou programa para rever. Gravações locais, arquivos e transmissão para outros dispositivos estão indisponíveis.",
        "Для SharePlay нужен прямой канал с названием, фильм, пронумерованная серия или архивная передача. Локальные записи, файлы и трансляция на другие устройства недоступны.",
        "SharePlay için adı olan bir canlı kanal, film, numaralı dizi bölümü veya arşiv programı gerekir. Yerel kayıtlar, dosyalar ve başka cihaza yayınlama kullanılamaz.",
        "SharePlay 需要有名称的直播频道、电影、带集数的剧集或回看节目。不支持本地录像、文件和投屏。",
    ],
    "shareplay_failed": ["Couldn’t start SharePlay. Check FaceTime and try again.", "تعذّر بدء SharePlay. تحقق من FaceTime وحاول مجددًا.", "SharePlay konnte nicht gestartet werden. Prüfe FaceTime und versuche es erneut.", "No se pudo iniciar SharePlay. Revisa FaceTime e inténtalo de nuevo.", "Impossible de démarrer SharePlay. Vérifiez FaceTime et réessayez.", "SharePlay शुरू नहीं हुआ। FaceTime जाँचें और फिर कोशिश करें।", "A SharePlay nem indítható el. Ellenőrizze a FaceTime-ot, és próbálja újra.", "Impossibile avviare SharePlay. Controlla FaceTime e riprova.", "SharePlayを開始できませんでした。FaceTimeを確認して、もう一度お試しください。", "Nie można rozpocząć SharePlay. Sprawdź FaceTime i spróbuj ponownie.", "Não foi possível iniciar o SharePlay. Verifique o FaceTime e tente novamente.", "Не удалось начать SharePlay. Проверьте FaceTime и повторите попытку.", "SharePlay başlatılamadı. FaceTime’ı kontrol edip yeniden deneyin.", "无法开始 SharePlay。请检查 FaceTime 通话后重试。"],
    "shareplay_call": ["Start or join a FaceTime call, then try SharePlay again.", "ابدأ مكالمة FaceTime أو انضم إليها، ثم حاول تشغيل SharePlay مجددًا.", "Starte einen FaceTime-Anruf oder tritt einem bei und versuche SharePlay erneut.", "Inicia una llamada de FaceTime o únete a una y vuelve a intentar SharePlay.", "Lancez ou rejoignez un appel FaceTime, puis réessayez SharePlay.", "FaceTime कॉल शुरू करें या उसमें जुड़ें, फिर SharePlay दोबारा आज़माएँ।", "Indítson FaceTime-hívást, vagy csatlakozzon egyhez, majd próbálja újra a SharePlayt.", "Avvia o partecipa a una chiamata FaceTime, poi riprova SharePlay.", "FaceTime通話を開始するか参加してから、もう一度SharePlayをお試しください。", "Rozpocznij rozmowę FaceTime lub dołącz do niej, a potem ponów próbę SharePlay.", "Inicie ou entre em uma chamada do FaceTime e tente o SharePlay novamente.", "Начните вызов FaceTime или присоединитесь к нему, затем попробуйте SharePlay снова.", "Bir FaceTime araması başlatın veya aramaya katılın, ardından SharePlay’i yeniden deneyin.", "请发起或加入 FaceTime 通话，然后重试 SharePlay。"],
    "shareplay_help": ["SharePlay"] * 14,
    "shareplay_help_body": [
        "Start or join a FaceTime call, start playback, then choose Start SharePlay in the player. Everyone needs this app and their own playlist and login. URLs and passwords are never sent to other participants. Channel changes, play and pause are shared. Seeking is synchronized only when the source supports seeking. Different provider delays mean live playback may not match frame for frame. Minimize and background playback keep SharePlay running. Stop playback leaves the session on this device. Leave SharePlay leaves just you; End for everyone ends the session for all participants. The signed app and its installation profile must include permission for SharePlay group sessions.",
        "ابدأ مكالمة FaceTime أو انضم إليها، وشغّل المحتوى، ثم اختر بدء SharePlay في المشغّل. يحتاج كل شخص إلى هذا التطبيق وقائمته وبيانات دخوله الخاصة. لا تُرسل الروابط وكلمات المرور إلى المشاركين الآخرين. تتم مشاركة تغيير القناة والتشغيل والإيقاف المؤقت. تتزامن الحركة داخل المحتوى فقط عندما يدعمها المصدر. قد تختلف الصورة في البث المباشر بسبب تأخر المزوّدين. يستمر SharePlay عند تصغير المشغّل والتشغيل في الخلفية. إيقاف التشغيل يغادر الجلسة على هذا الجهاز. مغادرة SharePlay تخرجك وحدك؛ إنهاء للجميع ينهي الجلسة لكل المشاركين. يجب أن يسمح توقيع التطبيق وملف تثبيته بجلسات SharePlay الجماعية.",
        "Starte einen FaceTime-Anruf oder tritt einem bei, starte die Wiedergabe und wähle im Player SharePlay starten. Alle benötigen diese App sowie ihre eigene Liste und Anmeldung. URLs und Passwörter werden nie an andere Teilnehmende gesendet. Senderwechsel, Wiedergabe und Pause werden geteilt. Spulen wird nur synchronisiert, wenn die Quelle es unterstützt. Unterschiedliche Verzögerungen der Anbieter können bei Live-Sendern zu abweichenden Bildern führen. Minimieren und Hintergrundwiedergabe lassen SharePlay weiterlaufen. Wiedergabe stoppen verlässt die Sitzung auf diesem Gerät. SharePlay verlassen beendet nur deine Teilnahme; Für alle beenden beendet die Sitzung für alle. Die signierte App und ihr Installationsprofil müssen SharePlay-Gruppensitzungen erlauben.",
        "Inicia una llamada de FaceTime o únete a una, reproduce contenido y elige Iniciar SharePlay en el reproductor. Todos necesitan esta app y su propia lista e inicio de sesión. Las URL y contraseñas nunca se envían a otros participantes. Se comparten los cambios de canal, la reproducción y la pausa. Los saltos de posición solo se sincronizan si la fuente lo permite. Los distintos retrasos de los proveedores pueden impedir que el directo coincida fotograma a fotograma. Minimizar y reproducir en segundo plano mantienen SharePlay activo. Detener la reproducción abandona la sesión en este dispositivo. Salir de SharePlay solo te saca a ti; Finalizar para todos termina la sesión para todos. La app firmada y su perfil de instalación deben permitir sesiones de grupo de SharePlay.",
        "Lancez ou rejoignez un appel FaceTime, démarrez la lecture, puis choisissez Démarrer SharePlay dans le lecteur. Chaque personne doit installer cette app et ajouter sa propre liste et ses identifiants. Les URL et mots de passe ne sont jamais envoyés aux autres participants. Les changements de chaîne, la lecture et la pause sont partagés. Les déplacements dans la lecture sont synchronisés uniquement si la source les permet. Les délais des fournisseurs peuvent empêcher une synchronisation image par image du direct. La réduction du lecteur et la lecture en arrière-plan maintiennent SharePlay. Arrêter la lecture quitte la session sur cet appareil. Quitter SharePlay ne retire que vous ; Terminer pour tout le monde termine la session pour tous. L’app signée et son profil d’installation doivent autoriser les sessions de groupe SharePlay.",
        "FaceTime कॉल शुरू करें या उसमें जुड़ें, सामग्री चलाएँ, फिर प्लेयर में SharePlay शुरू करें चुनें। सभी को यह ऐप और अपनी प्लेलिस्ट व लॉगिन चाहिए। URL और पासवर्ड दूसरे प्रतिभागियों को कभी नहीं भेजे जाते। चैनल बदलना, चलाना और रोकना साझा होता है। आगे-पीछे जाना तभी समन्वयित होता है जब स्रोत इसकी अनुमति दे। प्रदाताओं की अलग-अलग देरी के कारण लाइव वीडियो का हर फ़्रेम एक साथ दिखना ज़रूरी नहीं है। छोटा करने और बैकग्राउंड में चलाने पर SharePlay जारी रहता है। प्लेबैक बंद करने से इस डिवाइस पर सत्र छूट जाता है। SharePlay छोड़ें से केवल आप निकलते हैं; सभी के लिए समाप्त करें से सबका सत्र समाप्त होता है। साइन किए गए ऐप और उसके इंस्टॉलेशन प्रोफ़ाइल में SharePlay समूह सत्रों की अनुमति होनी चाहिए।",
        "Indítson FaceTime-hívást, vagy csatlakozzon egyhez, indítsa el a lejátszást, majd válassza a SharePlay indítása lehetőséget a lejátszóban. Mindenkinek telepítenie kell ezt az alkalmazást, és hozzá kell adnia saját listáját és fiókját. Az URL-ek és jelszavak soha nem kerülnek a többi résztvevőhöz. A csatornaváltás, indítás és szüneteltetés közös. A tekerés csak akkor szinkronizálódik, ha a forrás támogatja. A szolgáltatók eltérő késleltetése miatt az élő adás képkockái eltérhetnek. A kis méret és a háttérben lejátszás alatt a SharePlay működik. A lejátszás leállítása ezen az eszközön kilép a munkamenetből. A Kilépés a SharePlayből csak Önt lépteti ki; a Befejezés mindenkinél az összes résztvevőnél befejezi. Az aláírt alkalmazásnak és telepítési profiljának engedélyeznie kell a SharePlay csoportos munkameneteket.",
        "Avvia o partecipa a una chiamata FaceTime, avvia la riproduzione e scegli Avvia SharePlay nel lettore. Tutti devono installare questa app e aggiungere la propria lista e le proprie credenziali. URL e password non vengono mai inviati agli altri partecipanti. Cambi di canale, riproduzione e pausa sono condivisi. Gli spostamenti nella riproduzione sono sincronizzati solo se la sorgente li supporta. I diversi ritardi dei fornitori possono impedire che la diretta coincida fotogramma per fotogramma. Riduzione del lettore e riproduzione in background mantengono SharePlay attivo. Interrompere la riproduzione abbandona la sessione su questo dispositivo. Esci da SharePlay fa uscire solo te; Termina per tutti conclude la sessione per tutti. L’app firmata e il suo profilo di installazione devono consentire le sessioni di gruppo SharePlay.",
        "FaceTime通話を開始するか参加し、再生を始めてから、プレーヤーで「SharePlayを開始」を選びます。全員がこのアプリをインストールし、自分のプレイリストとログイン情報を追加する必要があります。URLとパスワードがほかの参加者に送られることはありません。チャンネル変更、再生、一時停止は共有されます。再生位置の移動は、対応する配信元でのみ同期されます。配信元ごとの遅延により、ライブ映像がフレーム単位で一致しないことがあります。最小化やバックグラウンド再生中もSharePlayは続きます。再生を停止すると、このデバイスはセッションから退出します。「SharePlayから退出」は自分だけ退出し、「全員のSharePlayを終了」は全員のセッションを終了します。署名済みアプリとインストール用プロファイルには、SharePlayグループセッションの許可が必要です。",
        "Rozpocznij rozmowę FaceTime lub dołącz do niej, włącz odtwarzanie i wybierz Rozpocznij SharePlay w odtwarzaczu. Każdy musi zainstalować tę aplikację oraz dodać własną listę i dane logowania. Adresy URL i hasła nigdy nie są wysyłane innym uczestnikom. Zmiany kanałów, odtwarzanie i pauza są wspólne. Przewijanie jest synchronizowane tylko wtedy, gdy źródło je obsługuje. Różne opóźnienia dostawców oznaczają, że obraz na żywo może różnić się między uczestnikami. Minimalizacja i odtwarzanie w tle nie przerywają SharePlay. Zatrzymanie odtwarzania opuszcza sesję na tym urządzeniu. Opuść SharePlay kończy tylko twój udział; Zakończ dla wszystkich kończy sesję wszystkim. Podpisana aplikacja i jej profil instalacyjny muszą zezwalać na sesje grupowe SharePlay.",
        "Inicie ou entre em uma chamada do FaceTime, comece a reprodução e escolha Iniciar SharePlay no reprodutor. Todos precisam instalar este app e adicionar a própria lista e os próprios dados de acesso. URLs e senhas nunca são enviados aos outros participantes. Mudanças de canal, reprodução e pausa são compartilhadas. Avançar e voltar só são sincronizados quando a fonte permite. Atrasos diferentes dos provedores podem impedir que a transmissão ao vivo coincida quadro a quadro. Minimizar e reproduzir em segundo plano mantêm o SharePlay ativo. Parar a reprodução sai da sessão neste dispositivo. Sair do SharePlay remove apenas você; Encerrar para todos termina a sessão de todos. O app assinado e seu perfil de instalação devem permitir sessões de grupo do SharePlay.",
        "Начните вызов FaceTime или присоединитесь к нему, включите воспроизведение и выберите Начать SharePlay в плеере. Всем нужно установить это приложение и добавить свой список и данные входа. URL и пароли никогда не передаются другим участникам. Переключение каналов, воспроизведение и пауза общие. Перемотка синхронизируется только для источников, которые её поддерживают. Из-за разных задержек провайдеров прямой эфир может не совпадать кадр в кадр. Сворачивание плеера и фоновое воспроизведение сохраняют SharePlay. Остановка воспроизведения выводит это устройство из сеанса. Выйти из SharePlay завершает только ваше участие; Завершить для всех завершает сеанс для всех. Подписанное приложение и его профиль установки должны разрешать групповые сеансы SharePlay.",
        "Bir FaceTime araması başlatın veya aramaya katılın, oynatmayı başlatın ve oynatıcıda SharePlay’i başlat’ı seçin. Herkes bu uygulamayı yükleyip kendi listesini ve giriş bilgilerini eklemelidir. URL’ler ve parolalar diğer katılımcılara asla gönderilmez. Kanal değişiklikleri, oynatma ve duraklatma paylaşılır. İleri ve geri sarma yalnızca kaynak destekliyorsa eşitlenir. Sağlayıcıların farklı gecikmeleri nedeniyle canlı görüntüler kare kare aynı olmayabilir. Küçültme ve arka planda oynatma SharePlay’i sürdürür. Oynatmayı durdurmak bu cihazı oturumdan çıkarır. SharePlay’den ayrıl yalnızca sizi çıkarır; Herkes için bitir oturumu tüm katılımcılar için bitirir. İmzalanmış uygulama ve yükleme profili SharePlay grup oturumlarına izin vermelidir.",
        "发起或加入 FaceTime 通话，开始播放，然后在播放器中选择“开始 SharePlay”。每个人都需要安装此应用，并添加自己的播放列表和登录信息。URL 和密码绝不会发送给其他参与者。频道切换、播放和暂停会共享。只有支持跳转的播放源才会同步播放位置。不同服务商的延迟可能导致直播画面无法逐帧一致。最小化和后台播放时，SharePlay 会继续运行。停止播放会让此设备离开会话。“离开 SharePlay”只让您退出；“为所有人结束”会结束所有参与者的会话。已签名的应用及其安装描述文件必须允许 SharePlay 群组会话。",
    ],
    "row_actions_hint": ["More actions available.", "تتوفر إجراءات أخرى.", "Weitere Aktionen verfügbar.", "Hay más acciones disponibles.", "D’autres actions sont disponibles.", "और क्रियाएँ उपलब्ध हैं।", "További műveletek érhetők el.", "Altre azioni disponibili.", "ほかの操作を利用できます。", "Dostępne są dodatkowe czynności.", "Mais ações disponíveis.", "Доступны другие действия.", "Başka eylemler kullanılabilir.", "有更多可用操作。"],
    "siri_failed": ["Couldn’t load this channel or guide. Open the app for details.", "تعذّر تحميل القناة أو الدليل. افتح التطبيق للتفاصيل.", "Sender oder Programm konnten nicht geladen werden. Öffne die App für Details.", "No se pudo cargar el canal o la guía. Abre la app para ver detalles.", "Impossible de charger la chaîne ou le guide. Ouvrez l’app pour les détails.", "चैनल या गाइड लोड नहीं हुई। विवरण के लिए ऐप खोलें।", "A csatorna vagy műsorújság nem tölthető be. A részletekhez nyissa meg az alkalmazást.", "Impossibile caricare il canale o la guida. Apri l’app per i dettagli.", "チャンネルまたは番組表を読み込めませんでした。詳細はアプリを開いてください。", "Nie można wczytać kanału lub programu. Otwórz aplikację po szczegóły.", "Não foi possível carregar o canal ou guia. Abra o app para detalhes.", "Не удалось загрузить канал или программу. Откройте приложение для подробностей.", "Kanal veya rehber yüklenemedi. Ayrıntılar için uygulamayı açın.", "无法加载频道或节目指南。请打开应用查看详情。"],
    "siri_shortcuts": ["Siri and Shortcuts", "Siri والاختصارات", "Siri und Kurzbefehle", "Siri y Atajos", "Siri et Raccourcis", "Siri और शॉर्टकट", "Siri és Parancsok", "Siri e Comandi Rapidi", "Siriとショートカット", "Siri i Skróty", "Siri e Atalhos", "Siri и Команды", "Siri ve Kestirmeler", "Siri 与快捷指令"],
    "siri_help": [
        "On iPhone, Siri and Shortcuts can tune channels by name or number, read what’s on now and next, search the guide, open a channel guide, and pause, resume or stop playback. Include the app name in your request. Siri asks for the search text. Add a playlist and open the app once to import its guide. Answers use the imported guide. These actions also work without Apple Intelligence; onscreen channel context needs iOS 18.2 or later and system support.",
        "على iPhone يستطيع Siri والاختصارات تشغيل القنوات بالاسم أو الرقم وقراءة البرنامج الحالي والتالي والبحث في الدليل وفتحه وإيقاف التشغيل مؤقتًا أو استئنافه أو إيقافه. اذكر اسم التطبيق في طلبك. يسأل Siri عن نص البحث. أضف قائمة وافتح التطبيق لاستيراد دليلها. الإجابات من الدليل المستورد. تعمل الإجراءات دون Apple Intelligence؛ سياق القناة على الشاشة يحتاج iOS 18.2 أو أحدث ودعم النظام.",
        "Auf dem iPhone können Siri und Kurzbefehle Sender nach Name oder Nummer einschalten, das aktuelle und nächste Programm vorlesen, das Programm durchsuchen, den Senderplan öffnen und die Wiedergabe pausieren, fortsetzen oder stoppen. Nenne den App-Namen. Siri fragt nach dem Suchtext. Füge eine Liste hinzu und öffne die App zum Programmimport. Antworten nutzen das importierte Programm. Die Aktionen funktionieren ohne Apple Intelligence; Bildschirmkontext benötigt iOS 18.2 oder neuer und Systemunterstützung.",
        "En iPhone, Siri y Atajos pueden sintonizar canales por nombre o número, leer el programa actual y siguiente, buscar en la guía, abrir la guía de un canal y pausar, reanudar o detener la reproducción. Incluye el nombre de la app. Siri pide el texto de búsqueda. Añade una lista y abre la app para importar su guía. Las respuestas usan la guía importada. Las acciones funcionan sin Apple Intelligence; el contexto en pantalla requiere iOS 18.2 o posterior y soporte del sistema.",
        "Sur iPhone, Siri et Raccourcis peuvent choisir une chaîne par nom ou numéro, lire le programme actuel et suivant, rechercher dans le guide, ouvrir le guide d’une chaîne et contrôler la lecture. Indiquez le nom de l’app. Siri demande le texte à chercher. Ajoutez une liste et ouvrez l’app pour importer son guide. Les réponses utilisent le guide importé. Ces actions fonctionnent sans Apple Intelligence ; le contexte à l’écran nécessite iOS 18.2 ou ultérieur et la prise en charge du système.",
        "iPhone पर Siri और शॉर्टकट नाम या नंबर से चैनल चला सकते हैं, अभी और आगे का कार्यक्रम पढ़ सकते हैं, गाइड खोज या खोल सकते हैं और चलाना रोक, जारी या बंद कर सकते हैं। अनुरोध में ऐप का नाम बोलें। Siri खोज का पाठ पूछता है। प्लेलिस्ट जोड़कर गाइड आयात करने के लिए ऐप खोलें। उत्तर आयातित गाइड से आते हैं। क्रियाएँ Apple Intelligence के बिना भी चलती हैं; स्क्रीन के चैनल संदर्भ के लिए iOS 18.2 या नया और सिस्टम समर्थन चाहिए।",
        "iPhone-on Siri és a Parancsok név vagy szám alapján csatornát indíthat, felolvashatja a jelenlegi és következő műsort, kereshet a műsorújságban, megnyithatja azt, és vezérelheti a lejátszást. Mondja ki az alkalmazás nevét is. Siri rákérdez a keresett szövegre. Adjon hozzá listát, majd nyissa meg az alkalmazást a műsorújság importálásához. A válaszok az importált adatokból származnak. A parancsok Apple Intelligence nélkül is működnek; a képernyő csatornakörnyezete iOS 18.2-et vagy újabbat és rendszertámogatást igényel.",
        "Su iPhone, Siri e Comandi Rapidi possono scegliere canali per nome o numero, leggere il programma attuale e successivo, cercare nella guida, aprire la guida di un canale e controllare la riproduzione. Includi il nome dell’app. Siri chiede il testo da cercare. Aggiungi una lista e apri l’app per importare la guida. Le risposte usano la guida importata. Le azioni funzionano senza Apple Intelligence; il contesto sullo schermo richiede iOS 18.2 o successivo e supporto del sistema.",
        "iPhoneではSiriとショートカットで名前や番号によるチャンネル選択、現在と次の番組の読み上げ、番組表の検索と表示、再生の一時停止・再開・停止ができます。アプリ名を含めて話してください。Siriが検索語を尋ねます。プレイリストを追加してアプリを開き、番組表を取り込んでください。回答は取り込んだ番組表を使います。操作はApple Intelligenceなしでも使えます。画面上のチャンネル情報の連携にはiOS 18.2以降とシステムの対応が必要です。",
        "Na iPhonie Siri i Skróty mogą włączać kanały po nazwie lub numerze, czytać bieżący i następny program, szukać w programie, otwierać program kanału i sterować odtwarzaniem. Podaj nazwę aplikacji. Siri zapyta o tekst wyszukiwania. Dodaj listę i otwórz aplikację, aby zaimportować program. Odpowiedzi używają zaimportowanych danych. Akcje działają bez Apple Intelligence; kontekst kanału na ekranie wymaga iOS 18.2 lub nowszego i wsparcia systemu.",
        "No iPhone, Siri e Atalhos podem sintonizar canais por nome ou número, ler o programa atual e seguinte, pesquisar no guia, abrir o guia de um canal e controlar a reprodução. Inclua o nome do app. A Siri pede o texto da pesquisa. Adicione uma lista e abra o app para importar o guia. As respostas usam o guia importado. As ações funcionam sem Apple Intelligence; o contexto na tela exige iOS 18.2 ou posterior e suporte do sistema.",
        "На iPhone Siri и Команды могут включать каналы по названию или номеру, читать текущую и следующую передачу, искать в программе, открывать программу канала и управлять воспроизведением. Назовите приложение в запросе. Siri спросит текст поиска. Добавьте список и откройте приложение для импорта программы. Ответы берутся из импортированных данных. Действия работают без Apple Intelligence; контекст канала на экране требует iOS 18.2 или новее и поддержки системы.",
        "iPhone’da Siri ve Kestirmeler ad veya numarayla kanal açabilir, şimdiki ve sonraki programı okuyabilir, rehberde arayabilir, kanal rehberini açabilir ve oynatmayı denetleyebilir. İsteğinize uygulama adını ekleyin. Siri arama metnini sorar. Liste ekleyip rehberi içe aktarmak için uygulamayı açın. Yanıtlar içe aktarılan rehberden gelir. Eylemler Apple Intelligence olmadan da çalışır; ekrandaki kanal bağlamı iOS 18.2 veya sonrası ve sistem desteği gerektirir.",
        "在 iPhone 上，Siri 和快捷指令可以按名称或编号播放频道、朗读当前及下个节目、搜索节目指南、打开频道节目指南，以及暂停、继续或停止播放。请求中请包含应用名称。Siri 会询问搜索内容。请先添加播放列表并打开应用导入节目指南。回答来自已导入的节目指南。操作无需 Apple Intelligence 也能使用；屏幕上的频道上下文需要 iOS 18.2 或更高版本及系统支持。",
    ],
    "channel": ["Channel", "قناة", "Sender", "Canal", "Chaîne", "चैनल", "Csatorna", "Canale", "チャンネル", "Kanał", "Canal", "Канал", "Kanal", "频道"],
    "tune_channel": ["Tune channel", "تشغيل قناة", "Sender einschalten", "Sintonizar canal", "Regarder une chaîne", "चैनल चलाएँ", "Csatorna lejátszása", "Riproduci canale", "チャンネルを再生", "Włącz kanał", "Sintonizar canal", "Включить канал", "Kanalı aç", "播放频道"],
    "whats_on_channel": ["What’s on this channel", "ما يُعرض على هذه القناة", "Was läuft auf diesem Sender", "Qué hay en este canal", "Programme de cette chaîne", "इस चैनल पर क्या चल रहा है", "Mi megy ezen a csatornán", "Cosa c’è su questo canale", "このチャンネルの番組", "Co jest na tym kanale", "O que passa neste canal", "Что идёт на этом канале", "Bu kanalda ne var", "此频道正在播放什么"],
    "channel_unavailable": ["This channel is no longer available. Choose another channel.", "لم تعد هذه القناة متاحة. اختر قناة أخرى.", "Dieser Sender ist nicht mehr verfügbar. Wähle einen anderen Sender.", "Este canal ya no está disponible. Elige otro canal.", "Cette chaîne n’est plus disponible. Choisissez-en une autre.", "यह चैनल अब उपलब्ध नहीं है। दूसरा चैनल चुनें।", "Ez a csatorna már nem érhető el. Válasszon másikat.", "Questo canale non è più disponibile. Scegline un altro.", "このチャンネルは利用できなくなりました。別のチャンネルを選んでください。", "Ten kanał nie jest już dostępny. Wybierz inny.", "Este canal não está mais disponível. Escolha outro.", "Этот канал больше недоступен. Выберите другой.", "Bu kanal artık kullanılamıyor. Başka bir kanal seçin.", "此频道已不可用。请选择其他频道。"],
    "playback_unavailable": ["Nothing is playing. Choose a channel first.", "لا يوجد تشغيل. اختر قناة أولًا.", "Es läuft nichts. Wähle zuerst einen Sender.", "No se está reproduciendo nada. Elige un canal primero.", "Aucune lecture en cours. Choisissez d’abord une chaîne.", "कुछ नहीं चल रहा है। पहले चैनल चुनें।", "Nincs lejátszás. Előbb válasszon csatornát.", "Nessuna riproduzione. Scegli prima un canale.", "何も再生していません。先にチャンネルを選んでください。", "Nic nie jest odtwarzane. Najpierw wybierz kanał.", "Nada está sendo reproduzido. Escolha um canal primeiro.", "Ничего не воспроизводится. Сначала выберите канал.", "Hiçbir şey oynatılmıyor. Önce bir kanal seçin.", "当前没有播放内容。请先选择频道。"],
    "browse": ["Browse", "تصفح", "Durchsuchen", "Explorar", "Parcourir", "ब्राउज़ करें", "Böngészés", "Sfoglia", "ブラウズ", "Przeglądaj", "Explorar", "Обзор", "Göz at", "浏览"],
    "minimize_player": ["Minimize", "تصغير", "Minimieren", "Minimizar", "Réduire", "छोटा करें", "Kis méret", "Riduci", "最小化", "Minimalizuj", "Minimizar", "Свернуть", "Küçült", "最小化"],
    "open_player": ["Open player", "فتح المشغل", "Player öffnen", "Abrir reproductor", "Ouvrir le lecteur", "प्लेयर खोलें", "Lejátszó megnyitása", "Apri lettore", "プレーヤーを開く", "Otwórz odtwarzacz", "Abrir player", "Открыть плеер", "Oynatıcıyı aç", "打开播放器"],
    "stop_playback": ["Stop playback", "إيقاف التشغيل", "Wiedergabe stoppen", "Detener reproducción", "Arrêter la lecture", "चलाना बंद करें", "Lejátszás leállítása", "Interrompi riproduzione", "再生を停止", "Zatrzymaj odtwarzanie", "Parar reprodução", "Остановить воспроизведение", "Oynatmayı durdur", "停止播放"],
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

# App Shortcuts use their own localization table and named placeholders.
SHORTCUTS = {
    "Play ${channel} in ${applicationName}": ["Play ${channel} in ${applicationName}", "شغّل ${channel} في ${applicationName}", "Spiele ${channel} in ${applicationName}", "Reproduce ${channel} en ${applicationName}", "Regarde ${channel} dans ${applicationName}", "${applicationName} में ${channel} चलाएँ", "${channel} lejátszása a(z) ${applicationName} alkalmazásban", "Riproduci ${channel} in ${applicationName}", "${applicationName}で${channel}を再生", "Włącz ${channel} w ${applicationName}", "Reproduzir ${channel} no ${applicationName}", "Включи ${channel} в ${applicationName}", "${applicationName} ile ${channel} oynat", "在${applicationName}中播放${channel}"],
    "What is on ${channel} in ${applicationName}": ["What is on ${channel} in ${applicationName}", "ماذا يُعرض على ${channel} في ${applicationName}", "Was läuft auf ${channel} in ${applicationName}", "Qué hay en ${channel} en ${applicationName}", "Que passe-t-il sur ${channel} dans ${applicationName}", "${applicationName} में ${channel} पर क्या चल रहा है", "Mi megy a(z) ${channel} csatornán a(z) ${applicationName} alkalmazásban", "Cosa c’è su ${channel} in ${applicationName}", "${applicationName}で${channel}の番組を確認", "Co jest na ${channel} w ${applicationName}", "O que passa em ${channel} no ${applicationName}", "Что идёт на ${channel} в ${applicationName}", "${applicationName} içinde ${channel} kanalında ne var", "${applicationName}中${channel}正在播放什么"],
    "Search the guide in ${applicationName}": ["Search the guide in ${applicationName}", "ابحث في الدليل في ${applicationName}", "Durchsuche das Programm in ${applicationName}", "Busca en la guía de ${applicationName}", "Cherche dans le guide de ${applicationName}", "${applicationName} में गाइड खोजें", "Műsorújság keresése a(z) ${applicationName} alkalmazásban", "Cerca nella guida di ${applicationName}", "${applicationName}で番組表を検索", "Szukaj w programie w ${applicationName}", "Pesquisar no guia do ${applicationName}", "Найди в программе ${applicationName}", "${applicationName} içinde rehberde ara", "在${applicationName}中搜索节目指南"],
    "Show the guide for ${channel} in ${applicationName}": ["Show the guide for ${channel} in ${applicationName}", "اعرض دليل ${channel} في ${applicationName}", "Zeige das Programm für ${channel} in ${applicationName}", "Muestra la guía de ${channel} en ${applicationName}", "Affiche le guide de ${channel} dans ${applicationName}", "${applicationName} में ${channel} की गाइड दिखाएँ", "A(z) ${channel} műsorújsága a(z) ${applicationName} alkalmazásban", "Mostra la guida di ${channel} in ${applicationName}", "${applicationName}で${channel}の番組表を表示", "Pokaż program ${channel} w ${applicationName}", "Mostrar o guia de ${channel} no ${applicationName}", "Покажи программу ${channel} в ${applicationName}", "${applicationName} içinde ${channel} rehberini göster", "在${applicationName}中显示${channel}节目指南"],
    "Pause playback in ${applicationName}": ["Pause playback in ${applicationName}", "أوقف التشغيل مؤقتًا في ${applicationName}", "Pausiere die Wiedergabe in ${applicationName}", "Pausa la reproducción en ${applicationName}", "Mets en pause dans ${applicationName}", "${applicationName} में चलाना रोकें", "Lejátszás szüneteltetése a(z) ${applicationName} alkalmazásban", "Metti in pausa in ${applicationName}", "${applicationName}で一時停止", "Wstrzymaj odtwarzanie w ${applicationName}", "Pausar reprodução no ${applicationName}", "Приостанови воспроизведение в ${applicationName}", "${applicationName} içinde oynatmayı duraklat", "暂停${applicationName}中的播放"],
    "Resume playback in ${applicationName}": ["Resume playback in ${applicationName}", "استأنف التشغيل في ${applicationName}", "Setze die Wiedergabe in ${applicationName} fort", "Reanuda la reproducción en ${applicationName}", "Reprends la lecture dans ${applicationName}", "${applicationName} में चलाना जारी रखें", "Lejátszás folytatása a(z) ${applicationName} alkalmazásban", "Riprendi la riproduzione in ${applicationName}", "${applicationName}で再生を再開", "Wznów odtwarzanie w ${applicationName}", "Retomar reprodução no ${applicationName}", "Продолжи воспроизведение в ${applicationName}", "${applicationName} içinde oynatmaya devam et", "继续${applicationName}中的播放"],
    "Stop playback in ${applicationName}": ["Stop playback in ${applicationName}", "أوقف التشغيل في ${applicationName}", "Stoppe die Wiedergabe in ${applicationName}", "Detén la reproducción en ${applicationName}", "Arrête la lecture dans ${applicationName}", "${applicationName} में चलाना बंद करें", "Lejátszás leállítása a(z) ${applicationName} alkalmazásban", "Interrompi la riproduzione in ${applicationName}", "${applicationName}で再生を停止", "Zatrzymaj odtwarzanie w ${applicationName}", "Parar reprodução no ${applicationName}", "Останови воспроизведение в ${applicationName}", "${applicationName} içinde oynatmayı durdur", "停止${applicationName}中的播放"],
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
    for key, values in {**EXTRA, **INFOPLIST, **SHORTCUTS}.items():
        if len(values) != len(ORDER):
            sys.exit(f"{key}: {len(values)} translations, need {len(ORDER)}")
    for phrase, translations in SHORTCUTS.items():
        parameters = sorted(re.findall(r"\$\{[^}]+\}", phrase))
        if any(sorted(re.findall(r"\$\{[^}]+\}", text)) != parameters for text in translations):
            sys.exit(f"{phrase}: shortcut translation changed its parameters")
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
        (d / "AppShortcuts.strings").write_text(strings_file({k: v[ORDER.index(lang)] for k, v in SHORTCUTS.items()}), encoding="utf-8", newline="\n")
        (d / "Localizable.stringsdict").write_text(stringsdict(merged_plurals), encoding="utf-8", newline="\n")
        info = {k: v[ORDER.index(lang)] for k, v in INFOPLIST.items()}
        info["CFBundleDisplayName"] = "Accessible IPTV"
        (d / "InfoPlist.strings").write_text(strings_file(info), encoding="utf-8", newline="\n")
        missing = [k for k in base if k not in strings and k not in untranslatable] if suffix else []
        print(f"{lang}: {len(merged)} strings, {len(merged_plurals)} plurals" + (f", English fallback for {missing}" if missing else ""))


if __name__ == "__main__":
    main()
