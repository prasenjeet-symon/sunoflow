/**
 * Shared look and feel for SunoFlow's transactional email.
 *
 * Tokens mirror site/assets/styles.css so email and site read as one product.
 * Mail clients strip <style> tags and half of CSS, so everything is inlined
 * and the layout is deliberately boring — the goal is "arrives everywhere,
 * reads well", in that order.
 *
 * NOTE: this is a .jsx source; the runtime module is the theme.js esbuild
 * writes next to the templates on build. Source templates therefore import
 * "./theme.js" — the same convention every emails/*.jsx uses.
 */
import {
  Body,
  Container,
  Head,
  Hr,
  Html,
  Preview,
  Text,
} from "@react-email/components";

/** Where every email's button lands: the dashboard, which holds the subscribe action. */
export const DASHBOARD_URL = "https://sunoflow-app.web.app/dashboard.html";

export const colors = {
  canvas: "#faf9f7",    // page background
  paper: "#ffffff",     // card
  ink: "#14141a",       // headings
  body: "#5b5b67",      // body copy
  faint: "#8d8d99",     // small print
  line: "#e7e5e0",      // rules
  accent: "#4f49b5",    // button
  accentInk: "#413b99", // links
};

const FONT =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';

export const style = {
  h1: {
    margin: "0 0 16px",
    fontSize: 22,
    lineHeight: 1.35,
    fontWeight: 700,
    letterSpacing: "-0.3px",
    color: colors.ink,
  },
  p: {
    margin: "0 0 14px",
    fontSize: 15,
    lineHeight: 1.6,
    color: colors.body,
  },
  bullet: {
    margin: "0 0 8px",
    fontSize: 15,
    lineHeight: 1.55,
    color: colors.body,
  },
  small: {
    margin: "18px 0 0",
    fontSize: 13,
    lineHeight: 1.55,
    color: colors.faint,
  },
  button: {
    background: colors.accent,
    borderRadius: "8px",
    color: "#ffffff",
    fontFamily: FONT,
    fontSize: 15,
    fontWeight: 600,
    padding: "12px 22px",
    textDecoration: "none",
  },
};

/**
 * Everything a template renders into: preheader, white card, footer.
 * Templates supply only the copy between the wordmark and the footer rule.
 */
export function Shell({ preview, children }) {
  return (
    <Html lang="en">
      <Head />
      <Preview>{preview}</Preview>
      <Body
        style={{
          margin: 0,
          padding: "28px 16px",
          backgroundColor: colors.canvas,
          fontFamily: FONT,
        }}
      >
        <Container
          style={{
            maxWidth: "520px",
            margin: "0 auto",
            backgroundColor: colors.paper,
            border: `1px solid ${colors.line}`,
            borderRadius: "14px",
            padding: "36px 32px 30px",
          }}
        >
          <Text
            style={{
              margin: "0 0 26px",
              fontSize: 17,
              fontWeight: 700,
              letterSpacing: "-0.2px",
              color: colors.ink,
            }}
          >
            SunoFlow
          </Text>
          {children}
          <Hr style={{ margin: "26px 0 14px", borderColor: colors.line }} />
          <Text style={{ margin: 0, fontSize: 12, lineHeight: 1.55, color: colors.faint }}>
            You're getting this because you started a SunoFlow trial. Manage your
            account in the{" "}
            <a href={DASHBOARD_URL} style={{ color: colors.accentInk }}>
              dashboard
            </a>
            .
          </Text>
        </Container>
      </Body>
    </Html>
  );
}