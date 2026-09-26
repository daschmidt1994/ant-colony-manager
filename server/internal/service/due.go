package service

import (
	"context"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Traffic light states.
const (
	DueOverdue = "overdue" // 🔴 date has passed
	DueSoon    = "soon"    // 🟡 today or within due_soon_days
	DueOK      = "ok"      // 🟢
	DuePaused  = "paused"  // winter rest pause
)

// Dashboard groups.
const (
	GroupOverdue  = "overdue"
	GroupToday    = "today"
	GroupTomorrow = "tomorrow"
	GroupWeek     = "this_week"
	GroupLater    = "later"
	GroupPaused   = "paused"
)

type DueTask struct {
	ScheduleID uuid.UUID  `json:"schedule_id"`
	ColonyID   uuid.UUID  `json:"colony_id"`
	TaskType   string     `json:"task_type"`
	Title      *string    `json:"title,omitempty"`
	LastDoneAt *time.Time `json:"last_done_at"`
	NextDueAt  *time.Time `json:"next_due_at"`
	Status     string     `json:"status"`
	Group      string     `json:"group"`
	Days       int        `json:"days"` // calendar days until due (negative = overdue)
}

// UserPrefs are the settings relevant for due calculations.
type UserPrefs struct {
	Location *time.Location
	SoonDays int
}

func (s *Service) userPrefs(ctx context.Context, q db.Querier, user uuid.UUID) UserPrefs {
	p := UserPrefs{Location: time.UTC, SoonDays: 1}
	var tz string
	if err := q.QueryRow(ctx, `SELECT timezone, due_soon_days FROM user_settings WHERE id = $1`, user).Scan(&tz, &p.SoonDays); err == nil {
		if loc, err := time.LoadLocation(tz); err == nil {
			p.Location = loc
		}
	}
	return p
}

// Classify computes status, group and day distance. It is the Go twin of the
// Dart DueCalculator; both are checked against test-vectors/due.json.
func Classify(next *time.Time, now time.Time, loc *time.Location, soonDays int) (status, group string, days int) {
	if next == nil {
		return DuePaused, GroupPaused, 0
	}
	days = calendarDays(now.In(loc), next.In(loc))
	switch {
	case days < 0:
		status = DueOverdue
	case days <= soonDays:
		status = DueSoon
	default:
		status = DueOK
	}
	switch {
	case days < 0:
		group = GroupOverdue
	case days == 0:
		group = GroupToday
	case days == 1:
		group = GroupTomorrow
	case days <= 6:
		group = GroupWeek
	default:
		group = GroupLater
	}
	return status, group, days
}

func calendarDays(from, to time.Time) int {
	a := time.Date(from.Year(), from.Month(), from.Day(), 0, 0, 0, 0, time.UTC)
	b := time.Date(to.Year(), to.Month(), to.Day(), 0, 0, 0, 0, time.UTC)
	return int(b.Sub(a).Hours() / 24)
}

// dueFor loads and classifies care tasks of the given colonies.
func (s *Service) dueFor(ctx context.Context, q db.Querier, prefs UserPrefs, colonies []uuid.UUID) (map[uuid.UUID][]DueTask, error) {
	rows, err := q.Query(ctx, `SELECT schedule_id, colony_id, task_type, title, last_done_at, next_due_at
		FROM care_due WHERE colony_id = ANY($1)`, colonies)
	if err != nil {
		return nil, err
	}
	tasks, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (DueTask, error) {
		var t DueTask
		err := r.Scan(&t.ScheduleID, &t.ColonyID, &t.TaskType, &t.Title, &t.LastDoneAt, &t.NextDueAt)
		return t, err
	})
	if err != nil {
		return nil, err
	}
	now := s.Now()
	out := map[uuid.UUID][]DueTask{}
	for _, t := range tasks {
		t.Status, t.Group, t.Days = Classify(t.NextDueAt, now, prefs.Location, prefs.SoonDays)
		out[t.ColonyID] = append(out[t.ColonyID], t)
	}
	for id := range out {
		sortDue(out[id])
	}
	return out, nil
}

func sortDue(ts []DueTask) {
	sort.SliceStable(ts, func(i, j int) bool {
		pi, pj := ts[i].Status == DuePaused, ts[j].Status == DuePaused
		if pi != pj {
			return !pi
		}
		return ts[i].Days < ts[j].Days
	})
}

// worst returns the most urgent task (tasks are sorted).
func worst(ts []DueTask) *DueTask {
	if len(ts) == 0 || ts[0].Status == DuePaused {
		return nil
	}
	return &ts[0]
}
