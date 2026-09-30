package service

import (
	"context"
	"errors"
	"strings"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
)

// pahoDial connects to an MQTT broker (3.1.1). After the first successful
// connection paho reconnects by itself; OnConnect runs after every connect.
func pahoDial(ctx context.Context, o MQTTOptions) (MQTTConn, error) {
	broker := o.URL
	if rest, ok := strings.CutPrefix(broker, "mqtts://"); ok {
		broker = "ssl://" + rest
	} else if rest, ok := strings.CutPrefix(broker, "mqtt://"); ok {
		broker = "tcp://" + rest
	}
	opts := paho.NewClientOptions().
		AddBroker(broker).
		SetClientID(o.ClientID).
		SetUsername(o.User).
		SetPassword(o.Password).
		SetCleanSession(true).
		SetConnectTimeout(10 * time.Second).
		SetKeepAlive(60 * time.Second).
		SetOrderMatters(false)
	if o.WillTopic != "" {
		opts.SetWill(o.WillTopic, "offline", 1, true).
			SetAutoReconnect(true).
			SetMaxReconnectInterval(time.Minute).
			SetOnConnectHandler(func(c paho.Client) {
				c.Publish(o.WillTopic, 1, true, "online")
				if o.HAStatusTopic != "" && o.OnHAOnline != nil {
					c.Subscribe(o.HAStatusTopic, 0, func(_ paho.Client, m paho.Message) {
						if string(m.Payload()) == "online" {
							o.OnHAOnline()
						}
					})
				}
				for filter, handle := range o.Subscribe {
					c.Subscribe(filter, 1, func(_ paho.Client, m paho.Message) { handle(m.Topic(), m.Payload()) })
				}
				if o.OnConnect != nil {
					o.OnConnect()
				}
			})
	} else {
		opts.SetAutoReconnect(false)
	}
	c := paho.NewClient(opts)
	if err := wait(ctx, c.Connect(), 15*time.Second); err != nil {
		c.Disconnect(0)
		return nil, err
	}
	return &pahoConn{c: c}, nil
}

func wait(ctx context.Context, t paho.Token, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	select {
	case <-t.Done():
		return t.Error()
	case <-ctx.Done():
		return errors.New("MQTT broker does not answer")
	}
}

type pahoConn struct{ c paho.Client }

func (p *pahoConn) Publish(topic string, payload []byte) error {
	return wait(context.Background(), p.c.Publish(topic, 1, true, payload), 10*time.Second)
}

func (p *pahoConn) Connected() bool { return p.c.IsConnectionOpen() }

func (p *pahoConn) Close() { p.c.Disconnect(250) }
