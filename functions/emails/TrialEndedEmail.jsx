/**
 * "Trial has ended" — composed on the first hourly sweep after `trialEndsAt`.
 *
 * Softens the 402 the gateway now returns for /cleanup: dictation has stopped,
 * activating resumes it, nothing the user set up was lost.
 */
import { Button, Heading, Text } from "@react-email/components";
import { Shell, style } from "./theme.js";

export function TrialEndedEmail({
  firstName = "there",
  endedOn = "",
  price = "₹99",
}) {
  return (
    <Shell preview="Your trial has ended — pick up where you left off.">
      <Heading style={style.h1}>Your free trial has ended</Heading>
      <Text style={style.p}>
        Hi {firstName} — your free trial ended{endedOn ? ` on ${endedOn}` : ""}.
        SunoFlow has paused until you activate: it won't dictate in the
        meantime.
      </Text>
      <Text style={style.p}>
        Nothing was taken away. The model, your settings and the vocabulary
        SunoFlow learned are all waiting — activating takes about a minute.
      </Text>
      <Button href="https://sunoflow-app.web.app/dashboard.html" style={style.button}>
        Activate subscription
      </Button>
      <Text style={style.small}>{price} a month after the trial, cancel any time.</Text>
      <Text style={style.small}>
        Already activated? You're all set — you can ignore this note.
      </Text>
    </Shell>
  );
}