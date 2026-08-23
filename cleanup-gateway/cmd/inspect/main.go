package main

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"
)

func main() {
	ctx := context.Background()
	fs, err := firestore.NewClient(ctx, "sunoflow-app")
	if err != nil {
		panic(err)
	}
	defer fs.Close()

	fmt.Println("=== apiKeys (device keys issued) ===")
	it := fs.Collection("apiKeys").Documents(ctx)
	uids := map[string]bool{}
	for {
		d, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			panic(err)
		}
		uid, _ := d.Data()["uid"].(string)
		rev := d.Data()["revokedAt"]
		uids[uid] = true
		fmt.Printf("  key %s…  uid=%s  revoked=%v\n", d.Ref.ID[:12], uid, rev != nil)
	}
	if len(uids) == 0 {
		fmt.Println("  (none)")
	}

	fmt.Println("\n=== does each of those uids have an account document? ===")
	for uid := range uids {
		snap, err := fs.Collection("users").Doc(uid).Get(ctx)
		if err != nil || !snap.Exists() {
			fmt.Printf("  uid=%s  ACCOUNT MISSING  -> gateway would answer 402 no_account\n", uid)
			continue
		}
		d := snap.Data()
		var trial string
		if t, ok := d["trialEndsAt"].(time.Time); ok {
			trial = t.Format("2006-01-02")
			if t.After(time.Now()) {
				trial += " (in date)"
			} else {
				trial += " (EXPIRED)"
			}
		}
		fmt.Printf("  uid=%s  plan=%v  trialEndsAt=%s\n", uid, d["plan"], trial)
	}
}
