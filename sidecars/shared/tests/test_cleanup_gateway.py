"""How the gateway's answers are classified — the paywall, at the HTTP level.

`/cleanup` is the only place a dictation is checked against the user's plan, so
the mapping from response to behaviour is the whole enforcement mechanism. Two
bugs lived here:

  * only 402 stopped a dictation, so a revoked device (401) kept working for
    free, and so did an unpaired install;
  * every transport error fell back to the raw transcript with no bound, so
    pointing the hostname at localhost was free dictation forever.

Both are pinned below against a real local HTTP server, not a mocked one. The
same scenarios run against the macOS sidecar's own copy in
``sidecar/tests/test_entitlement_parity.py``.
"""
import pytest

from sidecars.shared import cleanup, lease
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(cleanup, lease, monkeypatch, tmp_path)
    yield handle
    server.shutdown()
    server.server_close()


def both_paths():
    return gateway_stub.verdicts(cleanup, KEY)


# --- refusals stop the dictation, 401 as surely as 402 ------------------------

@pytest.mark.parametrize("status, error", [
    (402, "trial_expired"),
    (402, "canceled"),
    (401, "revoked"),      # the device was disconnected from the account
    (401, "invalid_key"),  # a key Firestore has never seen
    (401, "missing_key"),
    (403, "forbidden"),
])
def test_a_refusal_blocks_on_both_paths(gateway, status, error):
    gateway.replies(status, {"error": error, "message": "Nope."})
    assert both_paths() == {
        "cleanup_on": "blocked:not_entitled",
        "cleanup_off": "blocked:not_entitled",
    }


def test_the_gateways_wording_is_passed_through(gateway):
    gateway.replies(402, {"error": "trial_expired", "message": "Your free trial has ended."})
    with pytest.raises(cleanup.NotEntitled, match="Your free trial has ended."):
        cleanup.clean_with_gateway("hello world", key=KEY)


# --- an outage is bounded by the lease ----------------------------------------

def test_unreachable_without_a_lease_is_refused(gateway):
    """The /etc/hosts bypass: block the host, get nothing."""
    gateway.unreachable()
    assert both_paths() == {
        "cleanup_on": "blocked:unreachable",
        "cleanup_off": "blocked:unreachable",
    }


def test_unreachable_with_a_valid_lease_keeps_working(gateway):
    """A real outage must not cost a paying user their words."""
    gateway.bank_lease(KEY)
    gateway.unreachable()
    assert both_paths() == {"cleanup_on": "served", "cleanup_off": "served"}


def test_an_expired_lease_does_not_keep_working(gateway):
    gateway.bank_lease(KEY, ttl=-60)
    assert not lease.allows_offline(KEY)
    gateway.unreachable()
    assert both_paths() == {
        "cleanup_on": "blocked:unreachable",
        "cleanup_off": "blocked:unreachable",
    }


def test_another_devices_lease_does_not_transfer(gateway):
    gateway.bank_lease("sf_someone_elses_device")
    gateway.unreachable()
    assert both_paths()["cleanup_on"] == "blocked:unreachable"


@pytest.mark.parametrize("status", [429, 500, 502, 503])
def test_server_errors_defer_to_the_lease(gateway, status):
    gateway.replies(status, {"error": "boom"})
    assert both_paths()["cleanup_on"] == "blocked:unreachable"

    gateway.bank_lease(KEY)
    assert both_paths() == {"cleanup_on": "served", "cleanup_off": "served"}


# --- an intermediary is not our gateway ---------------------------------------

def test_a_proxys_401_page_is_an_outage_not_a_cancellation(gateway):
    """A misconfigured nginx in front of us must not tell every user their
    subscription was cancelled — but it must not hand out free dictation
    either, so it lands on the lease like any other outage."""
    gateway.replies(401, b"<html><body>401 Authorization Required</body></html>", "text/html")
    assert both_paths() == {
        "cleanup_on": "blocked:unreachable",
        "cleanup_off": "blocked:unreachable",
    }

    gateway.bank_lease(KEY)
    assert both_paths() == {"cleanup_on": "served", "cleanup_off": "served"}


# --- the happy path -----------------------------------------------------------

def test_an_entitled_call_returns_cleaned_text_and_banks_the_lease(gateway):
    token = gateway.issue_lease(KEY)
    gateway.replies(200, {"cleaned": "Hello world.", "lease": token})

    assert cleanup.clean_with_gateway("hello world", key=KEY) == "Hello world."
    assert lease.load() == token, "the lease was not banked; the next outage would lock the user out"

    # And that banked lease is what carries the next dictation through an outage.
    gateway.unreachable()
    assert cleanup.clean_with_gateway("hello world", key=KEY) == "hello world"


def test_an_empty_cleaned_field_falls_back_to_raw(gateway):
    gateway.replies(200, {"cleaned": "   "})
    assert cleanup.clean_with_gateway("hello world", key=KEY) == "hello world"


def test_an_unconnected_device_never_reaches_the_network(gateway):
    """No key means no dictation, on both paths, without asking anyone."""
    assert gateway_stub.verdicts(cleanup, "") == {
        "cleanup_on": "blocked:not_connected",
        "cleanup_off": "blocked:not_connected",
    }


# --- the user's dictionary on the wire ----------------------------------------

def test_the_dictionary_is_sent_when_there_is_one(gateway):
    """The whole feature is inert unless these entries reach the prompt."""
    entries = [
        {"from": "cavach", "to": "Kavach", "kind": "correction"},
        {"from": "my Instagram", "to": "https://instagram.com/someone", "kind": "expansion"},
    ]
    cleanup.clean_with_gateway("hello world", key=KEY, dictionary=entries)
    assert gateway.last_request()["dictionary"] == entries


def test_no_dictionary_field_when_nothing_is_relevant(gateway):
    """Nothing of the user's vocabulary leaves the machine on a dictation that
    did not touch any of it."""
    cleanup.clean_with_gateway("hello world", key=KEY, dictionary=[])
    assert "dictionary" not in gateway.last_request()
