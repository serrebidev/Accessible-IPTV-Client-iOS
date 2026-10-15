"""Builds Resources/<lang>.lproj/help.md from the Android app's raw*/help.md (29 blocks each).
Paragraphs that say Android things (TalkBack, Menu key, Movies folder, Android installs)
are replaced with the iOS wording below; the rest stays as the translators wrote it.

    python tools/build_help.py [path/to/android/app/src/main/res]
"""
import re
import sys
from pathlib import Path
from android_strings import EXTRA, ORDER

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RES = ROOT.parent / "accessible IPTV client Android" / "app" / "src" / "main" / "res"
LANGS = {"": "en", "ar": "ar", "de": "de", "es": "es", "fr": "fr", "hi": "hi", "hu": "hu", "it": "it",
         "ja": "ja", "pl": "pl", "pt-rBR": "pt-BR", "ru": "ru", "tr": "tr", "zh-rCN": "zh-Hans"}

# Block index in the Android help -> iOS replacement. "cast" goes after block 20;
# the CarPlay and Apple TV sections go at the end.
KEYS = {3: "s3", 5: "s5", 6: "s6", 11: "s11", 15: "s15", 16: "s16", 18: "s18", 20: "s20", 22: "s22", 23: "s23", 26: "s26", 28: "s28"}

IOS = {
    "en": {
        "s3": "Search is at the top. It searches every group in the section; exact names come first. Voice, next to it, fills it by speech. Clear empties it.",
        "s5": "Categories open first. Choose a category to see its channels; All is an explicit choice. On iPhone and iPad, the tabs are Browse, Guide, Recordings and Settings. On iPad, Apple TV and Vision Pro, categories appear on the left. Both lists have headings. Picking a category moves you to its channels.",
        "s6": "Number keys on a keyboard jump to that channel number.",
        "s11": "Actions rotor: play in another app, favourite, details, guide, record or stop recording, download. Without VoiceOver: touch and hold. On Apple TV: hold Select.",
        "s15": "On iPhone and iPad, Minimize keeps playback running in a miniplayer above the tabs. Tap its title or video to expand it. Pause and Stop playback are separate controls. The expanded player has Audio, Subtitles, Record, Cast and Full screen. Keys: A for audio, S for subtitles, F for full screen, Escape to minimize. With VoiceOver, a two-finger double tap plays and pauses.",
        "s16": "Full screen hides the buttons. A tap, Escape or the remote’s Back button brings them back.",
        "s18": "Subtitles from the stream are shown in the picture. A Subtitle file shows under the video and, for SRT and WebVTT, is spoken, unless Speak subtitles is off in Settings.",
        "s20": "A live stream that drops reconnects by itself. Sound keeps playing with the screen locked.",
        "cast": "Cast sends the stream to a Chromecast on the same network.",
        "s22": "Saved in the Files app: On My iPhone (or iPad), Accessible IPTV, Recordings. Recordings in progress are listed first; activate one to stop it.",
        "s23": "Scheduled recordings run 2 minutes past the end. Change the minutes before and after in Settings. The app stays awake in the background while it records, and when a recording starts within six hours. If the app was closed, a notification at the start time asks you to open it.",
        "s26": "Export settings saves playlists, logins, favourites and options to a file. Import settings loads one from this device, another one, or the Android app. Language opens this app’s page in the Settings app.",
        "s28": "The app checks for a new version once a day. More, Check for updates checks now. Install opens AltStore, which installs it.",
        "carplay": "CarPlay lists favourite and recently watched live channels and plays their sound. It needs a build signed with Apple’s CarPlay audio permission.",
        "tv": "Apple TV has no voice search, M3U files or settings files. The system can clear the app’s storage; lists and the guide then download again, and recordings can be lost.",
    },
    "de": {
        "s3": "Suchen ist oben. Es durchsucht alle Gruppen des Bereichs; exakte Namen zuerst. Sprache daneben füllt es per Spracheingabe. Löschen leert es.",
        "s5": "Zuerst erscheinen Kategorien. Wähle eine Kategorie für ihre Sender; Alle muss ausdrücklich gewählt werden. Auf iPhone und iPad gibt es die Tabs Durchsuchen, Programm, Aufnahmen und Einstellungen. Auf iPad, Apple TV und Vision Pro stehen Kategorien links. Beide Listen haben Überschriften. Eine Kategorie wählen führt zu ihren Sendern.",
        "s6": "Zifferntasten einer Tastatur springen zu dieser Sendernummer.",
        "s11": "Aktionen-Rotor: in anderer App abspielen, Favorit, Details, Programm, aufnehmen oder Aufnahme stoppen, herunterladen. Ohne VoiceOver: gedrückt halten. Auf Apple TV: Auswahltaste gedrückt halten.",
        "s15": "Auf iPhone und iPad läuft die Wiedergabe nach Minimieren im Miniplayer über den Tabs weiter. Titel oder Video antippen öffnet den Player. Pause und Wiedergabe stoppen sind getrennt. Der große Player bietet Ton, Untertitel, Aufnehmen, Streamen und Vollbild. Tasten: A für Ton, S für Untertitel, F für Vollbild, Escape zum Minimieren. Mit VoiceOver startet und pausiert ein Doppeltippen mit zwei Fingern.",
        "s16": "Vollbild blendet die Tasten aus. Tippen, Escape oder die Zurück-Taste der Fernbedienung holt sie zurück.",
        "s18": "Untertitel aus dem Stream erscheinen im Bild. Eine Untertiteldatei erscheint unter dem Video und wird bei SRT und WebVTT vorgelesen, außer Untertitel vorlesen ist in den Einstellungen aus.",
        "s20": "Ein abgebrochener Livestream verbindet sich selbst neu. Der Ton läuft bei gesperrtem Bildschirm weiter.",
        "cast": "Streamen schickt den Stream an ein Chromecast im selben Netzwerk.",
        "s22": "Gespeichert in der Dateien-App: Auf meinem iPhone (oder iPad), Accessible IPTV, Recordings. Laufende Aufnahmen stehen oben; aktivieren stoppt sie.",
        "s23": "Geplante Aufnahmen laufen 2 Minuten über das Ende. Die Minuten vorher und nachher stehen in den Einstellungen. Die App bleibt im Hintergrund wach, solange sie aufnimmt und wenn eine Aufnahme innerhalb von sechs Stunden beginnt. War die App geschlossen, bittet eine Mitteilung zur Startzeit, sie zu öffnen.",
        "s26": "Einstellungen exportieren speichert Listen, Zugangsdaten, Favoriten und Optionen in einer Datei. Einstellungen importieren lädt eine solche Datei von diesem Gerät, einem anderen oder der Android-App. Sprache öffnet die Seite dieser App in der Einstellungen-App.",
        "s28": "Die App sucht einmal am Tag nach einer neuen Version. Mehr, Nach Updates suchen prüft sofort. Installieren öffnet AltStore, das sie installiert.",
        "carplay": "CarPlay zeigt favorisierte und zuletzt gesehene Live-Sender und spielt ihren Ton. Dafür braucht es einen Build mit Apples CarPlay-Audio-Berechtigung.",
        "tv": "Apple TV hat keine Sprachsuche, keine M3U-Dateien und keine Einstellungsdateien. Das System kann den Speicher der App leeren; Listen und Programm werden dann neu geladen, Aufnahmen können verloren gehen.",
    },
    "fr": {
        "s3": "Rechercher est en haut. La recherche couvre tous les groupes de la section ; les noms exacts viennent en premier. Voix, à côté, la remplit par la parole. Effacer la vide.",
        "s5": "Les catégories s’ouvrent en premier. Choisissez une catégorie pour voir ses chaînes ; Toutes reste un choix explicite. Sur iPhone et iPad, les onglets sont Parcourir, Guide, Enregistrements et Réglages. Sur iPad, Apple TV et Vision Pro, les catégories sont à gauche. Les deux listes ont des titres. Choisir une catégorie mène à ses chaînes.",
        "s6": "Les touches numériques d’un clavier sautent à ce numéro de chaîne.",
        "s11": "Rotor Actions : lire dans une autre app, favori, détails, guide, enregistrer ou arrêter l’enregistrement, télécharger. Sans VoiceOver : toucher longuement. Sur Apple TV : maintenir Sélectionner.",
        "s15": "Sur iPhone et iPad, Réduire maintient la lecture dans un mini-lecteur au-dessus des onglets. Touchez son titre ou sa vidéo pour l’agrandir. Pause et Arrêter la lecture sont distincts. Le grand lecteur propose Audio, Sous-titres, Enregistrer, Caster et Plein écran. Touches : A pour l’audio, S pour les sous-titres, F pour le plein écran, Échap pour réduire. Avec VoiceOver, un double toucher à deux doigts lance ou met en pause.",
        "s16": "Le plein écran masque les boutons. Un toucher, Échap ou le bouton Retour de la télécommande les ramène.",
        "s18": "Les sous-titres du flux s’affichent dans l’image. Un fichier de sous-titres s’affiche sous la vidéo et, en SRT ou WebVTT, est lu à voix haute, sauf si Lire les sous-titres est désactivé dans Réglages.",
        "s20": "Un direct coupé se reconnecte tout seul. Le son continue écran verrouillé.",
        "cast": "Caster envoie le flux vers un Chromecast du même réseau.",
        "s22": "Enregistrés dans l’app Fichiers : Sur mon iPhone (ou iPad), Accessible IPTV, Recordings. Les enregistrements en cours sont listés en premier ; activez-en un pour l’arrêter.",
        "s23": "Les enregistrements programmés continuent 2 minutes après la fin. Changez les minutes avant et après dans Réglages. L’app reste active en arrière-plan pendant un enregistrement et quand un enregistrement commence dans les six heures. Si l’app était fermée, une notification à l’heure de début demande de l’ouvrir.",
        "s26": "Exporter les réglages enregistre listes, identifiants, favoris et options dans un fichier. Importer les réglages en charge un depuis cet appareil, un autre ou l’app Android. Langue ouvre la page de cette app dans l’app Réglages.",
        "s28": "L’app cherche une nouvelle version une fois par jour. Plus, Rechercher des mises à jour le fait tout de suite. Installer ouvre AltStore, qui l’installe.",
        "carplay": "CarPlay liste les chaînes en direct favorites et récemment regardées et diffuse leur son. Il faut une version signée avec l’autorisation audio CarPlay d’Apple.",
        "tv": "Apple TV n’a ni recherche vocale, ni fichiers M3U, ni fichiers de réglages. Le système peut vider le stockage de l’app ; les listes et le guide se rechargent alors, et des enregistrements peuvent être perdus.",
    },
    "es": {
        "s3": "Buscar está arriba. Busca en todos los grupos de la sección; los nombres exactos van primero. Voz, al lado, lo rellena hablando. Borrar lo vacía.",
        "s5": "Primero aparecen las categorías. Elige una para ver sus canales; Todos debe seleccionarse expresamente. En iPhone y iPad hay pestañas Explorar, Guía, Grabaciones y Ajustes. En iPad, Apple TV y Vision Pro, las categorías aparecen a la izquierda. Ambas listas tienen encabezados. Elegir una categoría lleva a sus canales.",
        "s6": "Las teclas numéricas de un teclado saltan a ese número de canal.",
        "s11": "Rotor de acciones: reproducir en otra app, favorito, detalles, guía, grabar o detener la grabación, descargar. Sin VoiceOver: mantén pulsado. En Apple TV: mantén pulsado Seleccionar.",
        "s15": "En iPhone y iPad, Minimizar mantiene la reproducción en un minirreproductor sobre las pestañas. Toca su título o vídeo para ampliarlo. Pausa y Detener reproducción son controles separados. El reproductor ampliado ofrece Audio, Subtítulos, Grabar, Enviar y Pantalla completa. Teclas: A para audio, S para subtítulos, F para pantalla completa, Escape para minimizar. Con VoiceOver, un doble toque con dos dedos reproduce y pausa.",
        "s16": "La pantalla completa oculta los botones. Un toque, Escape o el botón Atrás del mando los vuelve a mostrar.",
        "s18": "Los subtítulos de la emisión se ven en la imagen. Un archivo de subtítulos se muestra bajo el vídeo y, si es SRT o WebVTT, se lee en voz alta, salvo que Leer subtítulos esté desactivado en Ajustes.",
        "s20": "Un directo que se corta se reconecta solo. El sonido sigue con la pantalla bloqueada.",
        "cast": "Enviar manda la emisión a un Chromecast de la misma red.",
        "s22": "Se guardan en la app Archivos: En mi iPhone (o iPad), Accessible IPTV, Recordings. Las grabaciones en curso salen primero; activa una para detenerla.",
        "s23": "Las grabaciones programadas siguen 2 minutos tras el final. Cambia los minutos antes y después en Ajustes. La app sigue activa en segundo plano mientras graba y cuando una grabación empieza en menos de seis horas. Si la app estaba cerrada, una notificación a la hora de inicio pide abrirla.",
        "s26": "Exportar ajustes guarda listas, accesos, favoritos y opciones en un archivo. Importar ajustes carga uno desde este dispositivo, otro o la app de Android. Idioma abre la página de esta app en la app Ajustes.",
        "s28": "La app busca una versión nueva una vez al día. Más, Buscar actualizaciones lo hace ahora. Instalar abre AltStore, que la instala.",
        "carplay": "CarPlay muestra los canales en directo favoritos y vistos hace poco y reproduce su sonido. Necesita una versión firmada con el permiso de audio de CarPlay de Apple.",
        "tv": "Apple TV no tiene búsqueda por voz, archivos M3U ni archivos de ajustes. El sistema puede vaciar el almacenamiento de la app; entonces las listas y la guía se descargan de nuevo y las grabaciones pueden perderse.",
    },
    "it": {
        "s3": "Cerca è in alto. Cerca in tutti i gruppi della sezione; i nomi esatti vengono prima. Voce, accanto, la compila parlando. Cancella la svuota.",
        "s5": "Si aprono prima le categorie. Scegline una per vedere i canali; Tutti va scelto esplicitamente. Su iPhone e iPad ci sono le schede Sfoglia, Guida, Registrazioni e Impostazioni. Su iPad, Apple TV e Vision Pro le categorie sono a sinistra. Entrambi gli elenchi hanno intestazioni. Scegliere una categoria porta ai suoi canali.",
        "s6": "I tasti numerici di una tastiera saltano a quel numero di canale.",
        "s11": "Rotore Azioni: riproduci in un’altra app, preferito, dettagli, guida, registra o ferma registrazione, scarica. Senza VoiceOver: tocca e tieni premuto. Su Apple TV: tieni premuto Seleziona.",
        "s15": "Su iPhone e iPad, Riduci mantiene la riproduzione nel mini lettore sopra le schede. Tocca titolo o video per espanderlo. Pausa e Interrompi riproduzione sono separati. Il lettore espanso offre Audio, Sottotitoli, Registra, Trasmetti e Schermo intero. Tasti: A per audio, S per sottotitoli, F per schermo intero, Escape per ridurre. Con VoiceOver, un doppio tocco con due dita riproduce e mette in pausa.",
        "s16": "Lo schermo intero nasconde i pulsanti. Un tocco, Esc o il tasto Indietro del telecomando li riporta.",
        "s18": "I sottotitoli del flusso compaiono nell’immagine. Un file di sottotitoli compare sotto il video e, se SRT o WebVTT, viene letto, salvo che Leggi i sottotitoli sia disattivato in Impostazioni.",
        "s20": "Una diretta interrotta si ricollega da sola. L’audio continua a schermo bloccato.",
        "cast": "Trasmetti invia il flusso a un Chromecast nella stessa rete.",
        "s22": "Salvate nell’app File: Sul mio iPhone (o iPad), Accessible IPTV, Recordings. Le registrazioni in corso sono elencate per prime; attivane una per fermarla.",
        "s23": "Le registrazioni programmate durano 2 minuti oltre la fine. Cambia i minuti prima e dopo in Impostazioni. L’app resta attiva in background mentre registra e quando una registrazione inizia entro sei ore. Se l’app era chiusa, una notifica all’ora d’inizio chiede di aprirla.",
        "s26": "Esporta impostazioni salva liste, accessi, preferiti e opzioni in un file. Importa impostazioni ne carica uno da questo dispositivo, da un altro o dall’app Android. Lingua apre la pagina di questa app nell’app Impostazioni.",
        "s28": "L’app cerca una nuova versione una volta al giorno. Altro, Cerca aggiornamenti controlla subito. Installa apre AltStore, che la installa.",
        "carplay": "CarPlay elenca i canali in diretta preferiti e visti di recente e ne riproduce l’audio. Serve una build firmata con l’autorizzazione audio CarPlay di Apple.",
        "tv": "Apple TV non ha ricerca vocale, file M3U né file di impostazioni. Il sistema può svuotare la memoria dell’app; liste e guida si scaricano di nuovo e le registrazioni possono andare perse.",
    },
    "pt-BR": {
        "s3": "A Busca fica no topo. Busca em todos os grupos da seção; nomes exatos vêm primeiro. Voz, ao lado, preenche falando. Limpar apaga.",
        "s5": "As categorias aparecem primeiro. Escolha uma para ver os canais; Todos precisa ser escolhido explicitamente. No iPhone e iPad há abas Explorar, Guia, Gravações e Ajustes. No iPad, Apple TV e Vision Pro, as categorias ficam à esquerda. As duas listas têm títulos. Escolher uma categoria leva aos seus canais.",
        "s6": "As teclas numéricas de um teclado pulam para esse número de canal.",
        "s11": "Rotor de ações: reproduzir em outro app, favorito, detalhes, guia, gravar ou parar gravação, baixar. Sem VoiceOver: toque e segure. Na Apple TV: segure Selecionar.",
        "s15": "No iPhone e iPad, Minimizar mantém a reprodução em um miniplayer acima das abas. Toque no título ou vídeo para expandir. Pausar e Parar reprodução são controles separados. O player expandido oferece Áudio, Legendas, Gravar, Transmitir e Tela cheia. Teclas: A para áudio, S para legendas, F para tela cheia, Escape para minimizar. Com VoiceOver, um toque duplo com dois dedos reproduz e pausa.",
        "s16": "A tela cheia esconde os botões. Um toque, Esc ou o botão Voltar do controle traz de volta.",
        "s18": "Legendas do canal aparecem na imagem. Um arquivo de legendas aparece abaixo do vídeo e, se for SRT ou WebVTT, é lido em voz alta, a menos que Ler legendas esteja desativado em Configurações.",
        "s20": "Uma transmissão ao vivo que cai se reconecta sozinha. O som continua com a tela bloqueada.",
        "cast": "Transmitir envia o canal para um Chromecast na mesma rede.",
        "s22": "Salvas no app Arquivos: No Meu iPhone (ou iPad), Accessible IPTV, Recordings. Gravações em andamento aparecem primeiro; ative uma para pará-la.",
        "s23": "Gravações agendadas continuam 2 minutos após o fim. Mude os minutos antes e depois em Configurações. O app fica ativo em segundo plano enquanto grava e quando uma gravação começa em até seis horas. Se o app estava fechado, uma notificação na hora de início pede para abri-lo.",
        "s26": "Exportar configurações salva listas, logins, favoritos e opções em um arquivo. Importar configurações carrega um deste aparelho, de outro ou do app Android. Idioma abre a página deste app no app Ajustes.",
        "s28": "O app procura uma nova versão uma vez por dia. Mais, Procurar atualizações verifica agora. Instalar abre o AltStore, que faz a instalação.",
        "carplay": "O CarPlay lista os canais ao vivo favoritos e vistos recentemente e toca o som deles. Precisa de uma versão assinada com a permissão de áudio do CarPlay da Apple.",
        "tv": "A Apple TV não tem busca por voz, arquivos M3U nem arquivos de configurações. O sistema pode limpar o armazenamento do app; então as listas e o guia baixam de novo e gravações podem se perder.",
    },
    "pl": {
        "s3": "Szukaj jest na górze. Przeszukuje wszystkie grupy w sekcji; dokładne nazwy są pierwsze. Głos obok wypełnia je mową. Wyczyść je opróżnia.",
        "s5": "Najpierw otwierają się kategorie. Wybierz kategorię, aby zobaczyć jej kanały; Wszystkie wymaga osobnego wyboru. Na iPhonie i iPadzie są karty Przeglądaj, Program, Nagrania i Ustawienia. Na iPadzie, Apple TV i Vision Pro kategorie są po lewej. Obie listy mają nagłówki. Wybór kategorii przenosi do jej kanałów.",
        "s6": "Klawisze cyfr na klawiaturze przechodzą do kanału o tym numerze.",
        "s11": "Pokrętło Czynności: odtwórz w innej aplikacji, ulubiony, szczegóły, program, nagraj lub zatrzymaj nagrywanie, pobierz. Bez VoiceOver: dotknij i przytrzymaj. Na Apple TV: przytrzymaj Wybierz.",
        "s15": "Na iPhonie i iPadzie Minimalizuj utrzymuje odtwarzanie w miniodtwarzaczu nad kartami. Stuknij tytuł lub wideo, aby go rozwinąć. Pauza i Zatrzymaj odtwarzanie to osobne przyciski. Rozwinięty odtwarzacz oferuje Dźwięk, Napisy, Nagraj, Przesyłaj i Pełny ekran. Klawisze: A dźwięk, S napisy, F pełny ekran, Escape minimalizuje. Z VoiceOver dwukrotne stuknięcie dwoma palcami odtwarza i wstrzymuje.",
        "s16": "Pełny ekran ukrywa przyciski. Stuknięcie, Escape lub przycisk Wstecz pilota przywraca je.",
        "s18": "Napisy ze strumienia widać na obrazie. Plik napisów jest widoczny pod wideo, a SRT i WebVTT są też czytane, chyba że Czytaj napisy jest wyłączone w Ustawieniach.",
        "s20": "Przerwany kanał na żywo sam łączy się ponownie. Dźwięk gra dalej przy zablokowanym ekranie.",
        "cast": "Przesyłaj wysyła strumień do Chromecasta w tej samej sieci.",
        "s22": "Zapisane w aplikacji Pliki: Na moim iPhonie (lub iPadzie), Accessible IPTV, Recordings. Trwające nagrania są pierwsze na liście; aktywuj jedno, aby je zatrzymać.",
        "s23": "Zaplanowane nagrania trwają 2 minuty po końcu. Minuty przed i po zmienisz w Ustawieniach. Aplikacja działa w tle, gdy nagrywa i gdy nagranie zaczyna się w ciągu sześciu godzin. Jeśli aplikacja była zamknięta, powiadomienie o czasie startu prosi o jej otwarcie.",
        "s26": "Eksportuj ustawienia zapisuje listy, loginy, ulubione i opcje do pliku. Importuj ustawienia wczytuje taki plik z tego urządzenia, innego lub z aplikacji na Androida. Język otwiera stronę tej aplikacji w Ustawieniach.",
        "s28": "Aplikacja sprawdza nową wersję raz dziennie. Więcej, Sprawdź aktualizacje sprawdza od razu. Zainstaluj otwiera AltStore, który ją instaluje.",
        "carplay": "CarPlay pokazuje ulubione i ostatnio oglądane kanały na żywo i odtwarza ich dźwięk. Wymaga wersji podpisanej z uprawnieniem audio CarPlay od Apple.",
        "tv": "Apple TV nie ma wyszukiwania głosowego, plików M3U ani plików ustawień. System może wyczyścić pamięć aplikacji; listy i program pobiorą się wtedy ponownie, a nagrania mogą zniknąć.",
    },
    "ru": {
        "s3": "Поиск вверху. Он ищет во всех группах раздела; точные названия первыми. Голос рядом заполняет его речью. Очистить стирает.",
        "s5": "Сначала открываются категории. Выберите категорию для просмотра её каналов; Все нужно выбрать отдельно. На iPhone и iPad доступны вкладки Обзор, Программа, Записи и Настройки. На iPad, Apple TV и Vision Pro категории слева. У обоих списков есть заголовки. Выбор категории переводит к её каналам.",
        "s6": "Цифровые клавиши клавиатуры переходят к каналу с этим номером.",
        "s11": "Ротор действий: открыть в другом приложении, избранное, подробно, программа, записать или остановить запись, скачать. Без VoiceOver: коснитесь и удерживайте. На Apple TV: удерживайте кнопку выбора.",
        "s15": "На iPhone и iPad кнопка Свернуть оставляет воспроизведение в мини-плеере над вкладками. Нажмите название или видео, чтобы развернуть. Пауза и Остановить воспроизведение — отдельные кнопки. В развёрнутом плеере доступны Звук, Субтитры, Запись, Трансляция и Полный экран. Клавиши: A звук, S субтитры, F полный экран, Escape свернуть. С VoiceOver двойное касание двумя пальцами запускает и приостанавливает воспроизведение.",
        "s16": "Полный экран скрывает кнопки. Касание, Escape или кнопка «Назад» на пульте возвращает их.",
        "s18": "Субтитры потока показываются на изображении. Файл субтитров показывается под видео, а SRT и WebVTT ещё и озвучиваются, если в Настройках не выключено «Озвучивать субтитры».",
        "s20": "Прервавшийся эфир переподключается сам. Звук продолжает играть при заблокированном экране.",
        "cast": "Трансляция отправляет поток на Chromecast в той же сети.",
        "s22": "Сохраняются в приложении «Файлы»: На iPhone (или iPad), Accessible IPTV, Recordings. Идущие записи стоят первыми; активируйте запись, чтобы остановить её.",
        "s23": "Запланированные записи идут 2 минуты после конца. Минуты до и после меняются в Настройках. Приложение работает в фоне, пока пишет, и когда запись начнётся в ближайшие шесть часов. Если приложение было закрыто, уведомление в момент начала попросит открыть его.",
        "s26": "Экспорт настроек сохраняет плейлисты, логины, избранное и параметры в файл. Импорт настроек загружает такой файл с этого устройства, другого или из приложения для Android. Язык открывает страницу этого приложения в Настройках.",
        "s28": "Приложение раз в день проверяет новую версию. Ещё, Проверить обновления проверяет сразу. Установить открывает AltStore, который её установит.",
        "carplay": "CarPlay показывает избранные и недавно просмотренные каналы и воспроизводит их звук. Нужна сборка, подписанная с разрешением Apple на аудио в CarPlay.",
        "tv": "На Apple TV нет голосового поиска, файлов M3U и файлов настроек. Система может очистить хранилище приложения; тогда плейлисты и программа загрузятся заново, а записи могут пропасть.",
    },
    "tr": {
        "s3": "Arama en üstte. Bölümdeki tüm gruplarda arar; tam eşleşen adlar önce gelir. Yanındaki Ses, konuşarak doldurur. Temizle boşaltır.",
        "s5": "Önce kategoriler açılır. Kanalları görmek için kategori seçin; Tümü ayrıca seçilmelidir. iPhone ve iPad’de Göz at, Rehber, Kayıtlar ve Ayarlar sekmeleri vardır. iPad, Apple TV ve Vision Pro’da kategoriler soldadır. Her iki listenin başlığı vardır. Kategori seçmek kanallarına götürür.",
        "s6": "Klavyedeki rakam tuşları o kanal numarasına atlar.",
        "s11": "Eylemler rotoru: başka uygulamada oynat, favori, ayrıntılar, rehber, kaydet veya kaydı durdur, indir. VoiceOver olmadan: dokunup basılı tutun. Apple TV’de: Seç’i basılı tutun.",
        "s15": "iPhone ve iPad’de Küçült, oynatmayı sekmelerin üzerindeki mini oynatıcıda sürdürür. Genişletmek için başlığa veya videoya dokunun. Duraklat ve Oynatmayı durdur ayrı denetimlerdir. Büyük oynatıcıda Ses, Altyazılar, Kaydet, Yayınla ve Tam ekran bulunur. Tuşlar: ses için A, altyazı için S, tam ekran için F, küçültmek için Escape. VoiceOver ile iki parmakla çift dokunma oynatır ve duraklatır.",
        "s16": "Tam ekran düğmeleri gizler. Dokunma, Escape veya kumandanın Geri düğmesi onları geri getirir.",
        "s18": "Yayındaki altyazılar görüntüde gösterilir. Bir altyazı dosyası videonun altında gösterilir; SRT ve WebVTT ise ayrıca seslendirilir, Ayarlar’da Altyazıları seslendir kapalı değilse.",
        "s20": "Kopan canlı yayın kendiliğinden yeniden bağlanır. Ekran kilitliyken ses çalmaya devam eder.",
        "cast": "Yayınla, akışı aynı ağdaki bir Chromecast’e gönderir.",
        "s22": "Dosyalar uygulamasında kaydedilir: iPhone’umda (veya iPad’imde), Accessible IPTV, Recordings. Süren kayıtlar en üstte listelenir; durdurmak için birini etkinleştirin.",
        "s23": "Zamanlanmış kayıtlar bitişten sonra 2 dakika sürer. Önceki ve sonraki dakikaları Ayarlar’da değiştirin. Uygulama kayıt yaparken ve altı saat içinde başlayacak bir kayıt varken arka planda açık kalır. Uygulama kapalıysa, başlangıç saatinde bir bildirim onu açmanızı ister.",
        "s26": "Ayarları dışa aktar; listeleri, girişleri, favorileri ve seçenekleri bir dosyaya kaydeder. Ayarları içe aktar, böyle bir dosyayı bu cihazdan, başka bir cihazdan veya Android uygulamasından yükler. Dil, Ayarlar uygulamasında bu uygulamanın sayfasını açar.",
        "s28": "Uygulama günde bir kez yeni sürüm arar. Diğer, Güncellemeleri denetle hemen denetler. Yükle, onu yükleyen AltStore’u açar.",
        "carplay": "CarPlay favori ve son izlenen canlı kanalları listeler ve seslerini çalar. Apple’ın CarPlay ses izniyle imzalanmış bir sürüm gerekir.",
        "tv": "Apple TV’de sesli arama, M3U dosyası ve ayar dosyası yoktur. Sistem uygulamanın depolamasını temizleyebilir; o zaman listeler ve rehber yeniden indirilir, kayıtlar kaybolabilir.",
    },
    "hu": {
        "s3": "A Keresés felül van. A szakasz összes csoportjában keres; a pontos nevek elöl vannak. A mellette lévő Hang beszéddel tölti ki. A Törlés kiüríti.",
        "s5": "Először a kategóriák jelennek meg. Válasszon kategóriát a csatornáihoz; az Összes külön választás. iPhone-on és iPaden a lapfülek: Böngészés, Műsorújság, Rögzítések és Beállítások. iPaden, Apple TV-n és Vision Prón a kategóriák bal oldalon vannak. Mindkét listának van címsora. A kategória kiválasztása a csatornáihoz vezet.",
        "s6": "A billentyűzet számgombjai az adott csatornaszámra ugranak.",
        "s11": "Műveletek rotor: lejátszás másik alkalmazásban, kedvenc, részletek, műsorújság, rögzítés vagy rögzítés leállítása, letöltés. VoiceOver nélkül: érintse meg és tartsa. Apple TV-n: tartsa lenyomva a Kiválasztás gombot.",
        "s15": "iPhone-on és iPaden a Kis méret gomb után a lejátszás a lapfülek feletti minilejátszóban folytatódik. A címre vagy videóra koppintva újra megnyitható. A szüneteltetés és a lejátszás leállítása külön vezérlő. A nagy lejátszóban hangsáv, felirat, rögzítés, átküldés és teljes képernyő érhető el. Billentyűk: A hangsáv, S felirat, F teljes képernyő, Escape kis méret. VoiceOverrel a kétujjas dupla koppintás indít és szüneteltet.",
        "s16": "A teljes képernyő elrejti a gombokat. Koppintás, Escape vagy a távirányító Vissza gombja visszahozza őket.",
        "s18": "Az adás feliratai a képen jelennek meg. A Feliratfájl a videó alatt jelenik meg, SRT és WebVTT esetén fel is olvassa, kivéve ha a Feliratok felolvasása ki van kapcsolva a Beállításokban.",
        "s20": "A megszakadt élő adás magától újrakapcsolódik. Lezárt képernyőnél a hang tovább szól.",
        "cast": "Az Átküldés az adást egy ugyanazon a hálózaton lévő Chromecastra küldi.",
        "s22": "Mentés helye a Fájlok alkalmazásban: Saját iPhone (vagy iPad), Accessible IPTV, Recordings. A folyamatban lévő rögzítések elöl vannak; aktiváljon egyet a leállításához.",
        "s23": "Az ütemezett rögzítések a vége után még 2 percig futnak. Az előtte és utána perceket a Beállításokban módosíthatja. Az alkalmazás ébren marad a háttérben, amíg rögzít, és ha egy rögzítés hat órán belül indul. Ha az alkalmazás be volt zárva, a kezdéskor egy értesítés kéri, hogy nyissa meg.",
        "s26": "A Beállítások exportálása fájlba menti a listákat, fiókokat, kedvenceket és beállításokat. A Beállítások importálása betölt egy ilyen fájlt erről az eszközről, egy másikról vagy az Android-alkalmazásból. A Nyelv megnyitja ennek az alkalmazásnak az oldalát a Beállítások alkalmazásban.",
        "s28": "Az alkalmazás naponta egyszer keres új verziót. A Továbbiak, Frissítések keresése azonnal ellenőriz. A Telepítés megnyitja az AltStore-t, amely telepíti.",
        "carplay": "A CarPlay felsorolja a kedvenc és a legutóbb nézett élő csatornákat, és lejátssza a hangjukat. Ehhez az Apple CarPlay-hangjogosultságával aláírt build kell.",
        "tv": "Az Apple TV-n nincs hangalapú keresés, M3U fájl és beállításfájl. A rendszer törölheti az alkalmazás tárhelyét; ekkor a listák és a műsorújság újra letöltődnek, a rögzítések elveszhetnek.",
    },
    "ja": {
        "s3": "検索は一番上です。セクション内のすべてのグループを検索し、完全に一致する名前が先に出ます。隣の音声で話して入力できます。クリアで消えます。",
        "s5": "最初にカテゴリが開きます。カテゴリを選ぶと、そのチャンネルが表示されます。すべて表示する場合は「すべて」を選びます。iPhoneとiPadにはブラウズ、番組表、録画、設定のタブがあります。iPad、Apple TV、Vision Proではカテゴリは左側です。両方のリストに見出しがあります。カテゴリを選ぶとチャンネルに移動します。",
        "s6": "キーボードの数字キーでそのチャンネル番号に移動します。",
        "s11": "アクションローター: 他のアプリで再生、お気に入り、詳細、番組表、録画または録画停止、ダウンロード。VoiceOver なしでは長押し。Apple TV では選択ボタンを長押し。",
        "s15": "iPhoneとiPadでは「最小化」でタブの上のミニプレーヤーに再生を続けられます。タイトルや映像をタップすると開きます。一時停止と再生停止は別の操作です。開いたプレーヤーには音声、字幕、録画、キャスト、全画面があります。キーは音声がA、字幕がS、全画面がF、最小化がEscapeです。VoiceOverでは2本指のダブルタップで再生と一時停止を切り替えます。",
        "s16": "全画面ではボタンが隠れます。タップ、Escape、またはリモコンの戻るボタンで戻ります。",
        "s18": "ストリームの字幕は映像に表示されます。字幕ファイルは映像の下に表示され、SRT と WebVTT は読み上げもされます (設定の字幕を読み上げるがオフの場合を除く)。",
        "s20": "途切れたライブ配信は自動で再接続します。画面をロックしても音声は流れ続けます。",
        "cast": "キャストは同じネットワーク上の Chromecast にストリームを送ります。",
        "s22": "ファイル App に保存されます: このiPhone内 (または iPad)、Accessible IPTV、Recordings。録画中のものが先頭に並び、実行すると停止します。",
        "s23": "予約録画は終了後 2 分まで続きます。前後の分数は設定で変えられます。録画中と、6 時間以内に録画が始まるとき、アプリはバックグラウンドで動き続けます。アプリが閉じられていた場合は、開始時刻に通知でアプリを開くよう求めます。",
        "s26": "設定をエクスポートは、プレイリスト、ログイン、お気に入り、オプションをファイルに保存します。設定をインポートは、この機器、別の機器、または Android アプリのファイルを読み込みます。言語は設定 App のこのアプリのページを開きます。",
        "s28": "アプリは 1 日 1 回新しいバージョンを確認します。その他、アップデートを確認ですぐに確認します。インストールで AltStore が開き、インストールします。",
        "carplay": "CarPlay にはお気に入りと最近見たライブチャンネルが並び、音声を再生します。Apple の CarPlay オーディオ権限で署名されたビルドが必要です。",
        "tv": "Apple TV には音声検索、M3U ファイル、設定ファイルがありません。システムがアプリの保存領域を消すことがあり、その場合プレイリストと番組表は再ダウンロードされ、録画は失われることがあります。",
    },
    "zh-Hans": {
        "s3": "搜索在顶部。它搜索本分区的所有分组；完全匹配的名称排在前面。旁边的语音可通过说话填写。清除会清空它。",
        "s5": "首先显示分类。选择分类查看其中的频道；查看全部需要单独选择。iPhone 和 iPad 提供浏览、节目指南、录制和设置标签页。iPad、Apple TV 和 Vision Pro 的分类位于左侧。两个列表都有标题。选择分类后移至其频道。",
        "s6": "键盘上的数字键会跳到对应编号的频道。",
        "s11": "操作转子：用其他应用播放、收藏、详情、节目单、录制或停止录制、下载。不用 VoiceOver 时：按住。在 Apple TV 上：按住选择键。",
        "s15": "在 iPhone 和 iPad 上，最小化会在标签页上方的迷你播放器中继续播放。轻点标题或视频可展开。暂停和停止播放是独立控件。展开的播放器提供音频、字幕、录制、投屏和全屏。快捷键：A 选择音频，S 选择字幕，F 全屏，Escape 最小化。使用 VoiceOver 时，双指轻点两次可播放或暂停。",
        "s16": "全屏会隐藏按钮。轻点、Escape 或遥控器的返回键可让它们回来。",
        "s18": "流中的字幕显示在画面里。字幕文件显示在视频下方，SRT 和 WebVTT 还会朗读，除非设置中关闭了朗读字幕。",
        "s20": "中断的直播会自动重新连接。锁屏后声音继续播放。",
        "cast": "投屏会把流发送到同一网络中的 Chromecast。",
        "s22": "保存在“文件”App：我的 iPhone（或 iPad）、Accessible IPTV、Recordings。正在录制的排在最前；激活一项即可停止。",
        "s23": "预约录制会在结束后继续 2 分钟。可在设置中更改提前和延后的分钟数。录制期间，以及六小时内有录制开始时，应用会在后台保持运行。如果应用已关闭，开始时间会有通知提醒你打开它。",
        "s26": "导出设置会把播放列表、登录信息、收藏和选项保存到文件。导入设置可从本设备、其他设备或 Android 应用载入此文件。语言会在“设置”App 中打开本应用的页面。",
        "s28": "应用每天检查一次新版本。更多、检查更新会立即检查。安装会打开 AltStore 进行安装。",
        "carplay": "CarPlay 列出收藏和最近观看的直播频道并播放声音。需要使用带有 Apple CarPlay 音频权限签名的版本。",
        "tv": "Apple TV 没有语音搜索、M3U 文件和设置文件。系统可能清除应用的存储；之后播放列表和节目单会重新下载，录制可能丢失。",
    },
    "ar": {
        "s3": "البحث في الأعلى. يبحث في كل مجموعات القسم؛ الأسماء المطابقة تمامًا أولًا. زر صوت بجانبه يملؤه بالكلام. مسح يفرغه.",
        "s5": "تفتح الفئات أولًا. اختر فئة لعرض قنواتها؛ عرض الكل يحتاج إلى اختيار صريح. على iPhone وiPad توجد علامات تبويب تصفح والدليل والتسجيلات والإعدادات. على iPad وApple TV وVision Pro تظهر الفئات على اليسار. لكلتا القائمتين عناوين. اختيار فئة ينقلك إلى قنواتها.",
        "s6": "مفاتيح الأرقام في لوحة المفاتيح تنتقل إلى رقم القناة.",
        "s11": "دوار الإجراءات: تشغيل في تطبيق آخر، المفضلة، التفاصيل، الدليل، تسجيل أو إيقاف التسجيل، تنزيل. بدون VoiceOver: المس مع الاستمرار. على Apple TV: اضغط مطولًا على زر التحديد.",
        "s15": "على iPhone وiPad يبقي تصغير التشغيل مستمرًا في مشغل مصغر فوق علامات التبويب. اضغط العنوان أو الفيديو لتوسيعه. الإيقاف المؤقت وإيقاف التشغيل عنصران منفصلان. يقدم المشغل الموسع الصوت والترجمة والتسجيل والبث وملء الشاشة. المفاتيح: A للصوت وS للترجمة وF لملء الشاشة وEscape للتصغير. مع VoiceOver، النقر المزدوج بإصبعين يشغّل ويوقف مؤقتًا.",
        "s16": "ملء الشاشة يخفي الأزرار. نقرة أو Escape أو زر الرجوع في جهاز التحكم يعيدها.",
        "s18": "ترجمة البث تظهر في الصورة. ملف الترجمة يظهر تحت الفيديو، ويُقرأ بصوت عالٍ إن كان SRT أو WebVTT، ما لم تكن قراءة الترجمة متوقفة في الإعدادات.",
        "s20": "البث المباشر الذي ينقطع يعيد الاتصال تلقائيًا. يستمر الصوت والشاشة مقفلة.",
        "cast": "بث يرسل القناة إلى جهاز Chromecast على الشبكة نفسها.",
        "s22": "تُحفظ في تطبيق الملفات: على iPhone (أو iPad)، Accessible IPTV، Recordings. التسجيلات الجارية تظهر أولًا؛ فعّل أحدها لإيقافه.",
        "s23": "التسجيلات المجدولة تستمر دقيقتين بعد النهاية. غيّر دقائق ما قبل وما بعد في الإعدادات. يبقى التطبيق يعمل في الخلفية أثناء التسجيل وعندما يبدأ تسجيل خلال ست ساعات. إن كان التطبيق مغلقًا، يطلب إشعار عند وقت البدء فتحه.",
        "s26": "تصدير الإعدادات يحفظ القوائم وبيانات الدخول والمفضلة والخيارات في ملف. استيراد الإعدادات يحمّل ملفًا من هذا الجهاز أو جهاز آخر أو من تطبيق Android. اللغة تفتح صفحة هذا التطبيق في تطبيق الإعدادات.",
        "s28": "يبحث التطبيق عن إصدار جديد مرة يوميًا. المزيد، التحقق من التحديثات يتحقق الآن. تثبيت يفتح AltStore الذي يثبّته.",
        "carplay": "يعرض CarPlay القنوات المباشرة المفضلة والتي شوهدت مؤخرًا ويشغّل صوتها. يحتاج إلى نسخة موقّعة بإذن صوت CarPlay من Apple.",
        "tv": "لا يوجد في Apple TV بحث صوتي ولا ملفات M3U ولا ملفات إعدادات. قد يمسح النظام تخزين التطبيق؛ عندها تُنزَّل القوائم والدليل من جديد وقد تضيع التسجيلات.",
    },
    "hi": {
        "s3": "खोज सबसे ऊपर है। यह सेक्शन के सभी समूहों में खोजती है; सटीक नाम पहले आते हैं। बगल का आवाज़ बटन बोलकर भरता है। साफ़ करें इसे खाली करता है।",
        "s5": "पहले श्रेणियाँ खुलती हैं। चैनल देखने के लिए श्रेणी चुनें; सभी चैनल देखने के लिए सभी अलग से चुनना होगा। iPhone और iPad में ब्राउज़ करें, गाइड, रिकॉर्डिंग और सेटिंग्स टैब हैं। iPad, Apple TV और Vision Pro पर श्रेणियाँ बाईं ओर हैं। दोनों सूचियों में शीर्षक हैं। श्रेणी चुनने पर उसके चैनल खुलते हैं।",
        "s6": "कीबोर्ड की संख्या कुंजियाँ उस चैनल नंबर पर ले जाती हैं।",
        "s11": "क्रियाएँ रोटर: दूसरे ऐप में चलाएँ, पसंदीदा, विवरण, गाइड, रिकॉर्ड करें या रिकॉर्डिंग रोकें, डाउनलोड। VoiceOver के बिना: छूकर दबाए रखें। Apple TV पर: चुनें बटन दबाए रखें।",
        "s15": "iPhone और iPad पर छोटा करें से टैब के ऊपर मिनी प्लेयर में चलना जारी रहता है। बड़ा करने के लिए उसके शीर्षक या वीडियो पर टैप करें। रोकें और चलाना बंद करें अलग नियंत्रण हैं। बड़े प्लेयर में ऑडियो, उपशीर्षक, रिकॉर्ड, कास्ट और पूर्ण स्क्रीन हैं। कुंजियाँ: ऑडियो के लिए A, उपशीर्षक के लिए S, पूर्ण स्क्रीन के लिए F, छोटा करने के लिए Escape। VoiceOver के साथ दो उँगलियों से दो बार टैप चलाता और रोकता है।",
        "s16": "पूर्ण स्क्रीन बटन छिपा देती है। टैप, Escape या रिमोट का वापस बटन उन्हें लौटाता है।",
        "s18": "स्ट्रीम के उपशीर्षक तस्वीर में दिखते हैं। उपशीर्षक फ़ाइल वीडियो के नीचे दिखती है, और SRT व WebVTT पढ़ी भी जाती है, जब तक सेटिंग्स में उपशीर्षक पढ़ें बंद न हो।",
        "s20": "टूटी हुई लाइव स्ट्रीम अपने आप फिर जुड़ जाती है। स्क्रीन लॉक होने पर भी आवाज़ चलती रहती है।",
        "cast": "कास्ट स्ट्रीम को उसी नेटवर्क के Chromecast पर भेजता है।",
        "s22": "Files ऐप में सहेजी जाती हैं: On My iPhone (या iPad), Accessible IPTV, Recordings। चल रही रिकॉर्डिंग पहले दिखती हैं; रोकने के लिए किसी को सक्रिय करें।",
        "s23": "शेड्यूल की गई रिकॉर्डिंग अंत के बाद 2 मिनट चलती हैं। पहले और बाद के मिनट सेटिंग्स में बदलें। रिकॉर्डिंग के दौरान, और जब छह घंटे में कोई रिकॉर्डिंग शुरू होनी हो, ऐप बैकग्राउंड में चालू रहता है। अगर ऐप बंद था, तो शुरू होने के समय एक सूचना ऐप खोलने को कहती है।",
        "s26": "सेटिंग्स निर्यात करें प्लेलिस्ट, लॉगिन, पसंदीदा और विकल्प एक फ़ाइल में सहेजता है। सेटिंग्स आयात करें ऐसी फ़ाइल इस डिवाइस, किसी दूसरे डिवाइस या Android ऐप से लोड करता है। भाषा Settings ऐप में इस ऐप का पेज खोलता है।",
        "s28": "ऐप दिन में एक बार नया संस्करण जाँचता है। और, अपडेट जाँचें अभी जाँचता है। इंस्टॉल करें AltStore खोलता है, जो इसे इंस्टॉल करता है।",
        "carplay": "CarPlay पसंदीदा और हाल में देखे गए लाइव चैनल दिखाता है और उनकी आवाज़ चलाता है। इसके लिए Apple की CarPlay ऑडियो अनुमति से साइन किया गया बिल्ड चाहिए।",
        "tv": "Apple TV में आवाज़ खोज, M3U फ़ाइलें और सेटिंग्स फ़ाइलें नहीं हैं। सिस्टम ऐप का स्टोरेज साफ़ कर सकता है; तब प्लेलिस्ट और गाइड फिर से डाउनलोड होते हैं, और रिकॉर्डिंग खो सकती हैं।",
    },
}


def main():
    res = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RES
    for suffix, lang in LANGS.items():
        src = res / (f"raw-{suffix}" if suffix else "raw") / "help.md"
        blocks = re.split(r"\n\s*\n", src.read_text(encoding="utf-8").strip())
        if len(blocks) != 29:
            sys.exit(f"{src}: {len(blocks)} blocks, expected 29; update KEYS")
        t = IOS[lang]
        out = []
        for i, b in enumerate(blocks):
            out.append(t[KEYS[i]] if i in KEYS else b)
            if i == 20:
                out.append(t["cast"])
        out += ["# CarPlay", t["carplay"], "# Apple TV", t["tv"]]
        out += ["# " + EXTRA["siri_shortcuts"][ORDER.index(lang)], EXTRA["siri_help"][ORDER.index(lang)]]
        dest = ROOT / "Resources" / f"{lang}.lproj" / "help.md"
        dest.write_text("\n\n".join(out) + "\n", encoding="utf-8", newline="\n")
        print(lang, len(out), "blocks")


if __name__ == "__main__":
    main()
