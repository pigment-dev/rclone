package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/pigment-dev/rclone/core/internal/model"
)

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show daemon and job status",
		RunE: func(*cobra.Command, []string) error {
			if g.json {
				info, err := call("daemon.info", nil)
				if err != nil {
					return err
				}
				jobs, err := call("jobs.list", nil)
				if err != nil {
					return err
				}
				printJSON(json.RawMessage(fmt.Sprintf(`{"daemon":%s,"jobs":%s}`, info, jobs)))
				return nil
			}
			var info map[string]any
			if _, err := callInto("daemon.info", nil, &info); err != nil {
				return err
			}
			fmt.Printf("pdrcloned %v (rclone %v) pid %v, up %vs, %v running, RSS %s\n\n",
				info["daemonVersion"], info["rcloneVersion"], info["pid"], info["uptimeSec"], info["jobsRunning"], human(int64(info["rssBytes"].(float64))))
			return printJobs()
		},
	}
}

func printJobs() error {
	var res struct {
		Jobs []model.Job `json:"jobs"`
	}
	if _, err := callInto("jobs.list", nil, &res); err != nil {
		return err
	}
	w := table()
	fmt.Fprintln(w, "ID\tNAME\tDIRECTION\tSTATE\tPROGRESS\tLAST RUN\tDETAIL")
	for _, j := range res.Jobs {
		st := j.Status
		prog, last := "", "never"
		if st.Progress != nil {
			prog = fmt.Sprintf("%.0f%% %s/s", st.Progress.Percent, human(int64(st.Progress.Speed)))
		}
		if st.LastRun != nil {
			ok := "ok"
			if !st.LastRun.OK {
				ok = "failed"
			}
			last = fmt.Sprintf("%s %s", st.LastRun.StartedAt.Local().Format("Jan 2 15:04"), ok)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", j.ID, j.Name, j.Direction, st.State, prog, last, deref(st.Reason, ""))
	}
	return w.Flush()
}

// resolveJob accepts a job id or an exact name.
func resolveJob(arg string) (string, error) {
	if strings.HasPrefix(arg, "job_") {
		return arg, nil
	}
	var res struct {
		Jobs []model.Job `json:"jobs"`
	}
	raw, err := call("jobs.list", nil)
	if err != nil {
		return "", err
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return "", err
	}
	for _, j := range res.Jobs {
		if strings.EqualFold(j.Name, arg) {
			return j.ID, nil
		}
	}
	return "", fmt.Errorf("no job with id or name %q", arg)
}

func jobCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "job", Short: "Manage sync jobs"}
	simple := func(use, short, method string) *cobra.Command {
		return &cobra.Command{Use: use + " <id|name>", Short: short, Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
			id, err := resolveJob(args[0])
			if err != nil {
				return err
			}
			if printed, err := callInto(method, map[string]any{"id": id}, nil); err != nil || printed {
				return err
			}
			fmt.Println("ok")
			return nil
		}}
	}
	list := &cobra.Command{Use: "list", Short: "List jobs", RunE: func(*cobra.Command, []string) error {
		if g.json {
			_, err := callInto("jobs.list", nil, nil)
			return err
		}
		return printJobs()
	}}
	var dry, resync, wait bool
	run := &cobra.Command{Use: "run <id|name>", Short: "Run a job now", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		return runJob(args[0], dry, resync, wait)
	}}
	run.Flags().BoolVar(&dry, "dry-run", false, "only report what would change")
	run.Flags().BoolVar(&resync, "resync", false, "two-way: rebuild the baseline")
	run.Flags().BoolVarP(&wait, "wait", "w", false, "wait for the run to finish and show progress")
	var rwait bool
	resyncCmd := &cobra.Command{Use: "resync <id|name>", Short: "Rebuild the two-way baseline", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		return runJob(args[0], false, true, rwait)
	}}
	resyncCmd.Flags().BoolVarP(&rwait, "wait", "w", false, "wait for the run to finish")
	preview := &cobra.Command{Use: "preview <id|name>", Aliases: []string{"dry-run"}, Short: "Preview what a run would change", Args: cobra.ExactArgs(1), RunE: func(_ *cobra.Command, args []string) error {
		id, err := resolveJob(args[0])
		if err != nil {
			return err
		}
		var p model.Preview
		if printed, err := callInto("jobs.preview", map[string]any{"id": id}, &p); err != nil || printed {
			return err
		}
		fmt.Printf("%d to add, %d to update, %d to delete, %d excluded, %s to transfer\n", p.Adds, p.Updates, p.Deletes, p.Excluded, human(p.Bytes))
		for _, s := range p.Sample.Adds {
			fmt.Println("  + " + s)
		}
		for _, s := range p.Sample.Updates {
			fmt.Println("  * " + s)
		}
		for _, s := range p.Sample.Deletes {
			fmt.Println("  - " + s)
		}
		for _, e := range p.Sample.Excluded {
			fmt.Printf("  x %s  (%s)\n", e.Path, e.Rule)
		}
		return nil
	}}
	var file string
	create := &cobra.Command{Use: "create -f job.json", Short: "Create a job from a JSON definition (headless setups)", RunE: func(*cobra.Command, []string) error {
		if file == "" {
			return errUsage
		}
		b, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		var res struct {
			Job model.Job `json:"job"`
		}
		if printed, err := callInto("jobs.create", map[string]any{"job": json.RawMessage(b)}, &res); err != nil || printed {
			return err
		}
		fmt.Printf("created %s (%s), state %s\n", res.Job.ID, res.Job.Name, res.Job.Status.State)
		return nil
	}}
	create.Flags().StringVarP(&file, "file", "f", "", "job JSON file (fields as in docs/PROTOCOL.md)")
	explain := &cobra.Command{Use: "explain <id|name> <path>", Short: "Explain why a path is (not) synced", Args: cobra.ExactArgs(2), RunE: func(_ *cobra.Command, args []string) error {
		id, err := resolveJob(args[0])
		if err != nil {
			return err
		}
		var r struct {
			Included bool    `json:"included"`
			Rule     *string `json:"rule"`
		}
		if printed, err := callInto("jobs.explain", map[string]any{"id": id, "path": args[1]}, &r); err != nil || printed {
			return err
		}
		verdict := "synced"
		if !r.Included {
			verdict = "excluded"
		}
		fmt.Printf("%s: %s (%s)\n", args[1], verdict, deref(r.Rule, "no rule matched"))
		return nil
	}}
	cmd.AddCommand(list, run, resyncCmd, preview, create, explain,
		simple("pause", "Pause a job (stops the current run)", "jobs.pause"),
		simple("resume", "Resume a paused job", "jobs.resume"),
		simple("cancel", "Stop the current run", "jobs.cancel"),
		simple("delete", "Delete a job definition (no files are touched)", "jobs.delete"))
	return cmd
}

func runJob(arg string, dry, resync, wait bool) error {
	id, err := resolveJob(arg)
	if err != nil {
		return err
	}
	var r struct {
		RunID string `json:"runId"`
	}
	if printed, err := callInto("jobs.run", map[string]any{"id": id, "dryRun": dry, "resync": resync}, &r); err != nil || printed {
		return err
	}
	fmt.Println("started", r.RunID)
	if !wait {
		return nil
	}
	for {
		time.Sleep(time.Second)
		var res struct {
			Job model.Job `json:"job"`
		}
		if _, err := callInto("jobs.get", map[string]any{"id": id}, &res); err != nil {
			return err
		}
		st := res.Job.Status
		if st.State == model.StateRunning || st.State == model.StateQueued {
			if p := st.Progress; p != nil {
				fmt.Printf("\r%5.1f%%  %s / %s  %d/%d files  %s/s   ", p.Percent, human(p.Bytes), human(p.TotalBytes), p.Files, p.TotalFiles, human(int64(p.Speed)))
			}
			continue
		}
		fmt.Println()
		if lr := st.LastRun; lr != nil && lr.ID == r.RunID {
			if !lr.OK {
				return fmt.Errorf("run failed: %s", deref(lr.Error, "unknown error"))
			}
			fmt.Printf("done: %d file(s), %s, %d deleted, %d conflict(s)\n", lr.Files, human(lr.Bytes), lr.Deletes, lr.Conflicts)
		}
		return nil
	}
}
