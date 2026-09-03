package cleanup

import (
	"strings"
	"testing"
)

func TestResolveMapsBothPlatformsToTheSameEntry(t *testing.T) {
	// The point of one shared catalog: a breakdown by app has to be comparable
	// across macOS and Windows, so the bundle id and the process name for the
	// same product must land on the same name and category.
	mac, macCat, _ := App{ID: "com.tinyspeck.slackmacgap"}.Resolve()
	win, winCat, _ := App{ID: "slack.exe"}.Resolve()
	if mac != win || macCat != winCat {
		t.Fatalf("platforms disagree: mac=%q/%q win=%q/%q", mac, macCat, win, winCat)
	}
	if mac != "Slack" || macCat != CatChat {
		t.Fatalf("got %q/%q, want Slack/chat", mac, macCat)
	}
}

func TestResolveIsCaseAndWhitespaceInsensitive(t *testing.T) {
	name, cat, _ := App{ID: "  Com.Apple.Terminal "}.Resolve()
	if name != "Terminal" || cat != CatTerminal {
		t.Fatalf("got %q/%q, want Terminal/terminal", name, cat)
	}
}

func TestBrowserSiteOutranksTheBrowser(t *testing.T) {
	// "Google Chrome" is the least interesting true statement available about a
	// dictation: the site is the part that says what the user was doing.
	name, cat, reported := App{ID: "com.google.chrome", Site: "mail.google.com"}.Resolve()
	if name != "Gmail" || cat != CatEmail || reported != "Gmail" {
		t.Fatalf("got %q/%q/%q, want Gmail/email/Gmail", name, cat, reported)
	}
}

func TestBrowserSiteStripsWWWOnlyWhenTheCatalogWants(t *testing.T) {
	// github.com is listed bare, www.linkedin.com is listed with the prefix.
	if name, _, _ := (App{ID: "chrome.exe", Site: "www.github.com"}).Resolve(); name != "GitHub" {
		t.Fatalf("www.github.com resolved to %q, want GitHub", name)
	}
	if name, _, _ := (App{ID: "chrome.exe", Site: "www.linkedin.com"}).Resolve(); name != "LinkedIn" {
		t.Fatalf("www.linkedin.com resolved to %q, want LinkedIn", name)
	}
}

func TestUnknownHostInKnownBrowserIsCountedButNotNamed(t *testing.T) {
	// A bare host names where somebody works. It stays out of analytics, but
	// the dictation still has to be counted, so it becomes UnknownSite rather
	// than vanishing.
	name, cat, reported := App{
		ID:   "com.google.chrome",
		Site: "jira.some-employer-internal.example",
	}.Resolve()
	if reported != UnknownSite {
		t.Fatalf("reported %q, want %q", reported, UnknownSite)
	}
	if name != "Google Chrome" || cat != CatBrowser {
		t.Fatalf("got %q/%q, want Google Chrome/browser", name, cat)
	}
	if strings.Contains(reported, "employer") {
		t.Fatal("the private host reached the reportable name")
	}
}

func TestUnknownAppIsNeverReportedByName(t *testing.T) {
	// An id we do not recognise is an internal or personal tool. It is counted
	// as "other" and named nowhere.
	name, cat, reported := App{ID: "com.acme.internal.crm", Detail: "Ticket 88"}.Resolve()
	if reported != "" {
		t.Fatalf("reported %q for an unknown app; want empty", reported)
	}
	if name != "" || cat != CatOther {
		t.Fatalf("got %q/%q, want \"\"/other", name, cat)
	}
}

func TestAppSectionRendersNameCategoryAndDetail(t *testing.T) {
	got := strings.Join(appSection(App{
		ID:     "com.tinyspeck.slackmacgap",
		Detail: "#cleanup-gateway | Mirrorli",
	}), "\n")
	if !strings.Contains(got, appHeader) {
		t.Fatalf("missing header:\n%s", got)
	}
	if !strings.Contains(got, "Slack (chat) — #cleanup-gateway | Mirrorli") {
		t.Fatalf("unexpected line:\n%s", got)
	}
}

func TestAppSectionKeepsAnUnknownAppsTitle(t *testing.T) {
	// We have no name for the app, but the window title is still the best clue
	// the model gets about where the words are going, so it must survive.
	got := strings.Join(appSection(App{ID: "com.acme.internal.crm", Detail: "Invoice INV-4471"}), "\n")
	if !strings.Contains(got, "Invoice INV-4471") {
		t.Fatalf("title dropped:\n%s", got)
	}
}

func TestAppSectionIsOmittedWhenThereIsNothingToSay(t *testing.T) {
	if got := appSection(App{}); got != nil {
		t.Fatalf("got %v, want nil", got)
	}
	if got := appSection(App{ID: "com.acme.unknown"}); got != nil {
		t.Fatalf("unknown app with no title should render nothing, got %v", got)
	}
}

func TestAppSectionFlattensAndCapsTheTitle(t *testing.T) {
	long := strings.Repeat("a", appDetailMax+50)
	got := strings.Join(appSection(App{ID: "code.exe", Detail: "one\ttwo\nthree " + long}), "\n")
	if strings.Count(got, "\n") != 2 { // header, line, trailing blank
		t.Fatalf("title was not flattened to one line:\n%q", got)
	}
	if !strings.Contains(got, "one two three") {
		t.Fatalf("whitespace not collapsed:\n%s", got)
	}
	if len(got) > len(appHeader)+appDetailMax+80 {
		t.Fatalf("title not capped, section is %d chars", len(got))
	}
}

func TestBuildPromptPlacesAppAheadOfScreen(t *testing.T) {
	// APP is the more reliable of the two — it comes from the OS, not from
	// reading pixels — so the model should meet it first.
	got := BuildPrompt("the text", "", nil, "screen words",
		App{ID: "com.apple.terminal", Detail: "zsh"}, nil, ToneFaithful)
	ai, si := strings.Index(got, appHeader), strings.Index(got, "[SCREEN")
	if ai < 0 || si < 0 {
		t.Fatalf("missing a section: app=%d screen=%d", ai, si)
	}
	if ai > si {
		t.Fatal("APP should precede SCREEN")
	}
}

func TestEchoGuardCatchesTheAppHeaderButNotTheSpeaker(t *testing.T) {
	title := "Q3 planning notes for the Gravelines migration review"
	// The model reciting the block back at us is an echo.
	if !LooksLikeEcho(appHeader+" x", "x", "", nil, "", App{Detail: title}, nil, ToneFaithful) {
		t.Fatal("header echo not caught")
	}
	// The speaker dictating the document's own title into it is not.
	if LooksLikeEcho(title, title, "", nil, "", App{Detail: title}, nil, ToneFaithful) {
		t.Fatal("speaker's own words flagged as an echo")
	}
}

func TestWindowsRecoversTheSiteFromTheTabTitle(t *testing.T) {
	// The Windows client cannot read a browser's address bar, so the title is
	// all it has. macOS is unaffected — it always sends a host.
	name, cat, reported := App{
		ID:     "chrome.exe",
		Detail: "Inbox (12) - Gmail - Google Chrome",
	}.Resolve()
	if name != "Gmail" || cat != CatEmail || reported != "Gmail" {
		t.Fatalf("got %q/%q/%q, want Gmail/email/Gmail", name, cat, reported)
	}
}

func TestARealHostAlwaysBeatsTheTitle(t *testing.T) {
	// A title mentioning another service must never override an address the
	// client actually read.
	name, _, _ := App{
		ID:     "com.google.chrome",
		Site:   "github.com",
		Detail: "How we migrated off Gmail - GitHub",
	}.Resolve()
	if name != "GitHub" {
		t.Fatalf("title overrode the host: got %q, want GitHub", name)
	}
}

func TestTitleMarkersNeedWordBoundaries(t *testing.T) {
	if _, ok := siteFromTitle("Notional accounting for beginners"); ok {
		t.Fatal("matched 'notion' inside 'Notional'")
	}
	if _, ok := siteFromTitle("Inbox (12) - Gmail - Google Chrome"); !ok {
		t.Fatal("failed to match a punctuation-separated marker")
	}
	if _, ok := siteFromTitle("A quiet page about nothing"); ok {
		t.Fatal("matched a title with no service in it")
	}
}

func TestTitleFallbackOnlyAppliesToBrowsers(t *testing.T) {
	// A chat app whose window happens to mention Gmail is still that chat app.
	name, cat, _ := App{ID: "slack.exe", Detail: "#general | Gmail migration"}.Resolve()
	if name != "Slack" || cat != CatChat {
		t.Fatalf("got %q/%q, want Slack/chat", name, cat)
	}
}
