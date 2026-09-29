package api_test

import (
	"testing"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestFoodStockSyncsPerOwner(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ben := env.User(t, "Ben")
	var cricket string
	if err := env.Pool.QueryRow(t.Context(), `SELECT id::text FROM food_items WHERE owner_id IS NULL AND name = 'Heimchen'`).Scan(&cricket); err != nil {
		t.Fatal(err)
	}
	stock := testenv.NewID()
	r := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "food_stocks", EntityID: stock, Op: "create",
		Payload: testenv.Payload(map[string]any{"food_item_id": cricket, "name": "Heimchen", "kind": "stock",
			"quantity": 40, "unit": "piece", "reorder_below": 10, "best_before": "2026-12-01"})})
	if r.Results[0].Status != "applied" {
		t.Fatalf("create: %+v", r.Results[0])
	}
	culture := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "food_stocks", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"name": "Drosophila-Zucht", "kind": "culture", "care_interval_days": 14})})
	if culture.Results[0].Status != "applied" {
		t.Fatalf("culture: %+v", culture.Results[0])
	}

	seen := func(c *testenv.Client) int {
		n := 0
		for _, ch := range c.Pull(t, 0).Changes {
			if ch.Entity == "food_stocks" {
				n++
			}
		}
		return n
	}
	if seen(anna) != 2 || seen(ben) != 0 {
		t.Fatalf("anna sees %d, ben sees %d", seen(anna), seen(ben))
	}

	// invalid values and foreign references are rejected
	for _, p := range []map[string]any{
		{"name": "x", "kind": "fridge"},
		{"name": "x", "quantity": -1},
		{"name": ""},
		{"name": "x", "food_item_id": testenv.NewID()},
	} {
		r := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "food_stocks", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(p)})
		if r.Results[0].Status != "rejected" {
			t.Errorf("%v: %+v", p, r.Results[0])
		}
	}
	// Ben cannot change Anna's stock
	r = ben.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "food_stocks", EntityID: stock, Op: "update",
		Payload: testenv.Payload(map[string]any{"quantity": 0})})
	if r.Results[0].Status == "applied" {
		t.Fatal("ben changed anna's stock")
	}
}
