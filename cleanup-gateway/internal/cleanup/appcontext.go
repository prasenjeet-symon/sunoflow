package cleanup

import (
	"strings"
)

// App is what the client observed about the application the user dictated into.
// It is read on the user's own machine from the OS — the frontmost process and
// its focused window — so it costs nothing to collect and, unlike anything
// inferred from a screenshot, it is not a guess.
//
// ID is the platform's stable identifier: a bundle id on macOS
// ("com.tinyspeck.slackmacgap"), a process name on Windows ("slack.exe").
// Site is the host the user is on when ID is a browser ("mail.google.com"),
// empty otherwise — a browser tells you almost nothing on its own, since
// dictating into Gmail and dictating into a code review are the same process.
// Detail is the focused window's title, which is where browsers put the page
// title and editors put the filename.
type App struct {
	ID     string
	Site   string
	Detail string
}

// Category is the closed set of application kinds the gateway serves.
//
// The set lives here rather than in the three clients for the same reason the
// tone list does: an app that needs recategorising, or a new one worth naming,
// is then a gateway restart instead of a Mac release, a Windows release, and a
// wait for everyone to update. Clients send the raw platform id and nothing
// else; every meaning attached to it is decided on this side.
type Category string

const (
	CatBrowser     Category = "browser"
	CatEmail       Category = "email"
	CatChat        Category = "chat"
	CatEditor      Category = "editor"
	CatTerminal    Category = "terminal"
	CatNotes       Category = "notes"
	CatDocs        Category = "document"
	CatSpreadsheet Category = "spreadsheet"
	CatDesign      Category = "design"
	CatMeeting     Category = "meeting"
	CatTracker     Category = "issue tracker"
	CatOther       Category = "other"
)

type appEntry struct {
	Name string
	Cat  Category
}

// appCatalog maps a normalised platform id to a display name and a category.
// Both platforms share the table: the macOS bundle id and the Windows process
// name for the same product both point at the same entry, so a breakdown by app
// is comparable across the two.
var appCatalog = map[string]appEntry{
	// Browsers. The category is deliberately weak on its own — see App.Site.
	"com.google.chrome":       {"Google Chrome", CatBrowser},
	"chrome.exe":              {"Google Chrome", CatBrowser},
	"com.apple.safari":        {"Safari", CatBrowser},
	"org.mozilla.firefox":     {"Firefox", CatBrowser},
	"firefox.exe":             {"Firefox", CatBrowser},
	"com.microsoft.edgemac":   {"Microsoft Edge", CatBrowser},
	"msedge.exe":              {"Microsoft Edge", CatBrowser},
	"com.brave.browser":       {"Brave", CatBrowser},
	"brave.exe":               {"Brave", CatBrowser},
	"company.thebrowser.arc":  {"Arc", CatBrowser},
	"com.operasoftware.opera": {"Opera", CatBrowser},

	// Mail.
	"com.apple.mail":             {"Apple Mail", CatEmail},
	"com.microsoft.outlook":      {"Outlook", CatEmail},
	"outlook.exe":                {"Outlook", CatEmail},
	"com.readdle.smartemail-mac": {"Spark", CatEmail},
	"com.airmail.airmail2":       {"Airmail", CatEmail},
	"com.missiveapp.missive":     {"Missive", CatEmail},
	"com.superhuman.mail":        {"Superhuman", CatEmail},
	"com.mimestream.mimestream":  {"Mimestream", CatEmail},
	"com.apple.mobilesms":        {"Messages", CatChat},
	"com.tinyspeck.slackmacgap":  {"Slack", CatChat},
	"slack.exe":                  {"Slack", CatChat},
	"com.hnc.discord":            {"Discord", CatChat},
	"discord.exe":                {"Discord", CatChat},
	"com.microsoft.teams2":       {"Microsoft Teams", CatChat},
	"com.microsoft.teams":        {"Microsoft Teams", CatChat},
	"ms-teams.exe":               {"Microsoft Teams", CatChat},
	"net.whatsapp.whatsapp":      {"WhatsApp", CatChat},
	"whatsapp.exe":               {"WhatsApp", CatChat},
	"ru.keepcoder.telegram":      {"Telegram", CatChat},
	"telegram.exe":               {"Telegram", CatChat},
	"com.linkedin.linkedin":      {"LinkedIn", CatChat},
	"com.apple.ichat":            {"Messages", CatChat},
	"com.microsoft.skype":        {"Skype", CatChat},
	"com.zoom.chat":              {"Zoom", CatMeeting},
	"us.zoom.xos":                {"Zoom", CatMeeting},
	"zoom.exe":                   {"Zoom", CatMeeting},
	"com.google.chrome.app.meet": {"Google Meet", CatMeeting},

	// Editors and IDEs.
	"com.microsoft.vscode":           {"Visual Studio Code", CatEditor},
	"com.microsoft.visualstudiocode": {"Visual Studio Code", CatEditor},
	"code.exe":                       {"Visual Studio Code", CatEditor},
	"com.todesktop.230313mzl4w4u92":  {"Cursor", CatEditor},
	"cursor.exe":                     {"Cursor", CatEditor},
	"com.apple.dt.xcode":             {"Xcode", CatEditor},
	"com.jetbrains.intellij":         {"IntelliJ IDEA", CatEditor},
	"idea64.exe":                     {"IntelliJ IDEA", CatEditor},
	"com.jetbrains.pycharm":          {"PyCharm", CatEditor},
	"pycharm64.exe":                  {"PyCharm", CatEditor},
	"com.jetbrains.goland":           {"GoLand", CatEditor},
	"com.sublimetext.4":              {"Sublime Text", CatEditor},
	"devenv.exe":                     {"Visual Studio", CatEditor},
	"com.zed.zed":                    {"Zed", CatEditor},

	// Terminals.
	"com.apple.terminal":    {"Terminal", CatTerminal},
	"com.googlecode.iterm2": {"iTerm", CatTerminal},
	"dev.warp.warp-stable":  {"Warp", CatTerminal},
	"windowsterminal.exe":   {"Windows Terminal", CatTerminal},
	"powershell.exe":        {"PowerShell", CatTerminal},
	"wt.exe":                {"Windows Terminal", CatTerminal},

	// Notes, documents, spreadsheets.
	"com.apple.notes":         {"Apple Notes", CatNotes},
	"md.obsidian":             {"Obsidian", CatNotes},
	"obsidian.exe":            {"Obsidian", CatNotes},
	"notion.id":               {"Notion", CatNotes},
	"notion.exe":              {"Notion", CatNotes},
	"com.bear-writer":         {"Bear", CatNotes},
	"com.apple.textedit":      {"TextEdit", CatDocs},
	"notepad.exe":             {"Notepad", CatDocs},
	"com.microsoft.word":      {"Microsoft Word", CatDocs},
	"winword.exe":             {"Microsoft Word", CatDocs},
	"com.apple.iwork.pages":   {"Pages", CatDocs},
	"com.microsoft.excel":     {"Microsoft Excel", CatSpreadsheet},
	"excel.exe":               {"Microsoft Excel", CatSpreadsheet},
	"com.apple.iwork.numbers": {"Numbers", CatSpreadsheet},

	// Design and trackers.
	"com.figma.desktop":  {"Figma", CatDesign},
	"figma.exe":          {"Figma", CatDesign},
	"com.linear":         {"Linear", CatTracker},
	"linear.exe":         {"Linear", CatTracker},
	"com.atlassian.jira": {"Jira", CatTracker},
}

// siteCatalog names the web applications worth counting separately. A browser's
// process id says nothing useful — dictating a pull request review and dictating
// a reply to your mother are both "Google Chrome" — so the host is what carries
// the meaning.
//
// It is an allowlist rather than a passthrough on purpose. A bare host is not
// harmless: "jira.some-employer-internal.example" names where somebody works.
// Well-known public services are counted by name and everything else is counted
// as "other site", which answers "what do people dictate into" without turning
// analytics into a record of the user's employer, clients or private servers.
var siteCatalog = map[string]appEntry{
	"mail.google.com":     {"Gmail", CatEmail},
	"outlook.office.com":  {"Outlook Web", CatEmail},
	"outlook.live.com":    {"Outlook Web", CatEmail},
	"github.com":          {"GitHub", CatTracker},
	"gitlab.com":          {"GitLab", CatTracker},
	"linear.app":          {"Linear", CatTracker},
	"www.notion.so":       {"Notion", CatNotes},
	"notion.so":           {"Notion", CatNotes},
	"docs.google.com":     {"Google Docs", CatDocs},
	"sheets.google.com":   {"Google Sheets", CatSpreadsheet},
	"app.slack.com":       {"Slack", CatChat},
	"web.whatsapp.com":    {"WhatsApp Web", CatChat},
	"www.linkedin.com":    {"LinkedIn", CatChat},
	"x.com":               {"X", CatChat},
	"twitter.com":         {"X", CatChat},
	"www.reddit.com":      {"Reddit", CatOther},
	"chatgpt.com":         {"ChatGPT", CatOther},
	"claude.ai":           {"Claude", CatOther},
	"gemini.google.com":   {"Gemini", CatOther},
	"www.figma.com":       {"Figma", CatDesign},
	"calendar.google.com": {"Google Calendar", CatOther},
	"meet.google.com":     {"Google Meet", CatMeeting},
	"stackoverflow.com":   {"Stack Overflow", CatOther},
	"www.upwork.com":      {"Upwork", CatOther},
	"mail.proton.me":      {"Proton Mail", CatEmail},
	"app.hubspot.com":     {"HubSpot", CatOther},
	"app.frontapp.com":    {"Front", CatEmail},
	"teams.microsoft.com": {"Microsoft Teams", CatChat},
	"discord.com":         {"Discord", CatChat},
	"www.canva.com":       {"Canva", CatDesign},
}

// UnknownSite is what an off-allowlist host is counted as. It is a real value
// rather than an empty one so "somewhere we don't have a name for" stays
// visible in the numbers instead of looking like missing data.
const UnknownSite = "other site"

// Resolve turns what the client observed into the display name and category the
// gateway uses. For a browser the site decides both when we recognise it: the
// user is in Gmail, and calling that "Google Chrome / browser" would throw away
// the only part worth knowing.
//
// The second return is the name safe to report to analytics: a catalog entry, a
// catalog site, UnknownSite for an unrecognised host in a known browser, or ""
// for an app we have no name for. It is never the raw id — an id we don't
// recognise is somebody's internal or personal tool, and counting it by name
// would put that in a third-party dashboard.
func (a App) Resolve() (display string, cat Category, reportable string) {
	id := normalizeID(a.ID)
	entry, known := appCatalog[id]

	if known && entry.Cat == CatBrowser {
		host := normalizeHost(a.Site)
		if site, ok := siteCatalog[host]; ok {
			return site.Name, site.Cat, site.Name
		}
		if host != "" {
			return entry.Name, CatBrowser, UnknownSite
		}
		// No host. macOS always sends one, so this is the Windows client, which
		// has no way to read a browser's address without a UI Automation
		// dependency it does not carry. The tab title is the next best thing:
		// browsers put the page title in it, and a service's own pages nearly
		// always name the service. It is a heuristic and it is only consulted
		// when there is no address to be had.
		if site, ok := siteFromTitle(a.Detail); ok {
			return site.Name, site.Cat, site.Name
		}
		return entry.Name, CatBrowser, entry.Name
	}
	if known {
		return entry.Name, entry.Cat, entry.Name
	}
	// Unrecognised app: still worth a category in the prompt if the client gave
	// us something human-readable, but nothing goes to analytics by name.
	return "", CatOther, ""
}

func normalizeID(id string) string {
	return strings.ToLower(strings.TrimSpace(id))
}

// titleMarkers recovers a site from a browser tab title, for clients that
// cannot read the address bar. Each marker must be distinctive enough that its
// appearance in a title means the user is really on that service — "Gmail" is
// safe, "Docs" or "Mail" would not be — because the only thing standing between
// a marker and a wrong answer is how specific the word is.
var titleMarkers = []struct {
	marker string
	entry  appEntry
}{
	{"gmail", siteCatalog["mail.google.com"]},
	{"github", siteCatalog["github.com"]},
	{"gitlab", siteCatalog["gitlab.com"]},
	{"google docs", siteCatalog["docs.google.com"]},
	{"google sheets", siteCatalog["sheets.google.com"]},
	{"linkedin", siteCatalog["www.linkedin.com"]},
	{"stack overflow", siteCatalog["stackoverflow.com"]},
	{"notion", siteCatalog["www.notion.so"]},
	{"chatgpt", siteCatalog["chatgpt.com"]},
	{"reddit", siteCatalog["www.reddit.com"]},
	{"outlook", siteCatalog["outlook.office.com"]},
	{"whatsapp", siteCatalog["web.whatsapp.com"]},
	{"proton mail", siteCatalog["mail.proton.me"]},
}

// siteFromTitle matches on word boundaries so "Gmail" is found in
// "Inbox (12) - Gmail - Google Chrome" but not inside an unrelated longer word.
func siteFromTitle(title string) (appEntry, bool) {
	t := strings.ToLower(title)
	for _, m := range titleMarkers {
		if containsWord(t, m.marker) {
			return m.entry, true
		}
	}
	return appEntry{}, false
}

// containsWord reports whether `word` appears in `s` bounded by non-letters on
// both sides. Titles are punctuation-heavy — "Inbox (12) - Gmail - Chrome" — so
// the boundary test has to accept separators, not just spaces.
func containsWord(s, word string) bool {
	for i := 0; i+len(word) <= len(s); i++ {
		if s[i:i+len(word)] != word {
			continue
		}
		if i > 0 && isLetter(s[i-1]) {
			continue
		}
		if end := i + len(word); end < len(s) && isLetter(s[end]) {
			continue
		}
		return true
	}
	return false
}

func isLetter(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// normalizeHost lowercases and drops a leading "www." only when the catalog
// does not list the www form itself, so entries like "www.linkedin.com" still
// match exactly.
func normalizeHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	h = strings.TrimSuffix(h, ".")
	if _, ok := siteCatalog[h]; ok {
		return h
	}
	return strings.TrimPrefix(h, "www.")
}

// appSection renders the APP block. It is reference material in exactly the
// sense SCREEN and CONTEXT are — it tells the model where the words are going,
// so it can pick the register and the spelling that fit, and nothing more. It
// is placed ahead of SCREEN because it is the more reliable of the two: it comes
// from the OS rather than from reading pixels.
func appSection(a App) []string {
	display, cat, _ := a.Resolve()
	detail := collapseWhitespace(strings.TrimSpace(a.Detail))
	if len(detail) > appDetailMax {
		detail = detail[:appDetailMax]
	}
	if display == "" && detail == "" {
		return nil
	}

	line := display
	switch {
	case line == "" && cat != CatOther:
		line = string(cat)
	case line != "":
		line = line + " (" + string(cat) + ")"
	}
	if detail != "" {
		if line != "" {
			line += " — " + detail
		} else {
			line = detail
		}
	}
	if line == "" {
		return nil
	}
	return []string{appHeader, line, ""}
}

// appDetailMax caps the window title. Titles are usually short, but a browser
// tab can carry a whole headline and an editor can carry a full path; the cap
// keeps a pathological one from crowding out the transcript.
const appDetailMax = 200

// collapseWhitespace folds every run of whitespace into a single space. Window
// titles arrive with tabs and newlines in them often enough to be worth
// flattening: the APP block is one line, and a title containing a newline would
// otherwise split it in two and read as a second, unlabelled section.
func collapseWhitespace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
