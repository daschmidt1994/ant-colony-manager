package mail

import (
	"context"
	"testing"
)

func TestSwitchUsesCurrentSender(t *testing.T) {
	w := NewSwitch(disabled{})
	if w.Enabled() {
		t.Fatal("disabled sender reports enabled")
	}
	rec := &Recorder{}
	w.Set(rec)
	if !w.Enabled() {
		t.Fatal("switch did not take the new sender")
	}
	if err := w.Send(context.Background(), Message{To: "a@b.c", Subject: "x"}); err != nil || len(rec.Messages()) != 1 {
		t.Fatalf("send via switch: %v %v", err, rec.Messages())
	}
	w.Set(disabled{})
	if w.Enabled() {
		t.Fatal("switch still enabled after disabling")
	}
}
