// Package mail sends transactional e-mails via SMTP. Without SMTP configuration
// it is disabled and callers fall back to admin/CLI flows.
package mail

import (
	"context"
	"crypto/tls"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/smtp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
)

type Message struct {
	To      string
	Subject string
	Body    string // plain text
}

type Sender interface {
	Enabled() bool
	Send(ctx context.Context, m Message) error
}

func New(cfg config.SMTPConfig, log *slog.Logger) Sender {
	if !cfg.Enabled() {
		return disabled{}
	}
	return &smtpSender{cfg: cfg, log: log}
}

type disabled struct{}

func (disabled) Enabled() bool                       { return false }
func (disabled) Send(context.Context, Message) error { return nil }

type smtpSender struct {
	cfg config.SMTPConfig
	log *slog.Logger
}

func (s *smtpSender) Enabled() bool { return true }

func (s *smtpSender) Send(ctx context.Context, m Message) error {
	if strings.ContainsAny(m.To, "\r\n") || strings.ContainsAny(m.Subject, "\r\n") {
		return fmt.Errorf("invalid header value")
	}
	addr := net.JoinHostPort(s.cfg.Host, strconv.Itoa(s.cfg.Port))
	dialer := &net.Dialer{Timeout: 15 * time.Second}
	var conn net.Conn
	var err error
	if s.cfg.TLS == "tls" {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: s.cfg.Host, MinVersion: tls.VersionTLS12})
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", addr)
	}
	if err != nil {
		return fmt.Errorf("smtp connect: %w", err)
	}
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	c, err := smtp.NewClient(conn, s.cfg.Host)
	if err != nil {
		return err
	}
	defer c.Close()
	if s.cfg.TLS == "starttls" {
		if err := c.StartTLS(&tls.Config{ServerName: s.cfg.Host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("smtp starttls: %w", err)
		}
	}
	if s.cfg.User != "" {
		if err := c.Auth(smtp.PlainAuth("", s.cfg.User, s.cfg.Password, s.cfg.Host)); err != nil {
			return fmt.Errorf("smtp auth: %w", err)
		}
	}
	if err := c.Mail(s.cfg.From); err != nil {
		return err
	}
	if err := c.Rcpt(m.To); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	msg := "From: " + s.cfg.From + "\r\n" +
		"To: " + m.To + "\r\n" +
		"Subject: " + mime.QEncoding.Encode("utf-8", m.Subject) + "\r\n" +
		"Date: " + time.Now().Format(time.RFC1123Z) + "\r\n" +
		"MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" +
		strings.ReplaceAll(m.Body, "\n", "\r\n")
	if _, err := w.Write([]byte(msg)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}

// Recorder captures messages in tests.
type Recorder struct {
	mu       sync.Mutex
	messages []Message
}

func (r *Recorder) Enabled() bool { return true }

func (r *Recorder) Send(_ context.Context, m Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.messages = append(r.messages, m)
	return nil
}

// Messages returns a copy of all recorded messages.
func (r *Recorder) Messages() []Message {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Message(nil), r.messages...)
}

// Switch is a Sender whose configuration can change at runtime (SMTP settings
// edited in the app). Sends always use the configuration current at call time.
type Switch struct {
	mu  sync.RWMutex
	cur Sender
}

func NewSwitch(initial Sender) *Switch { return &Switch{cur: initial} }

// Set replaces the active sender.
func (w *Switch) Set(s Sender) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.cur = s
}

func (w *Switch) get() Sender {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.cur
}

func (w *Switch) Enabled() bool                             { return w.get().Enabled() }
func (w *Switch) Send(ctx context.Context, m Message) error { return w.get().Send(ctx, m) }
