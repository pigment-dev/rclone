package demo

import (
	"context"
	"time"
)

// Runner is the subset of the daemon the demo loop drives.
type Runner interface {
	RunNow(jobID, reason string) (string, error)
}

// Loop keeps the Projects upload running: start, wait for the simulated
// run to finish, pause a few seconds, repeat.
func Loop(ctx context.Context, d Runner, e *Engine) {
	for {
		if _, err := d.RunNow(JobProjects, "files changed"); err != nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
				continue
			}
		}
		for done := false; !done; {
			select {
			case <-ctx.Done():
				return
			case id := <-e.Finished:
				done = id == JobProjects
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(4 * time.Second):
		}
	}
}
