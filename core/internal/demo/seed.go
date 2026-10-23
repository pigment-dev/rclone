package demo

import (
	"context"
	"time"

	"github.com/pigment-dev/rclone/core/internal/config"
	"github.com/pigment-dev/rclone/core/internal/model"
	"github.com/pigment-dev/rclone/core/internal/paths"
	"github.com/pigment-dev/rclone/core/internal/store"
)

// Fixed ids keep screenshots reproducible.
const (
	AccWork     = "acc_work01"
	AccPersonal = "acc_pers02"
	AccBackups  = "acc_bkps03"
	AccNAS      = "acc_nas004"

	JobProjects  = "job_proj01"
	JobDocuments = "job_docs02"
	JobWebsite   = "job_site03"
	JobNAS       = "job_nas004"
	JobNotes     = "job_note05"
)

// HomeUser is the fake user shown in paths.
const HomeUser = "/Users/alex"

// SystemState is the simulated environment: on a café Wi-Fi, so the NAS
// job (home Wi-Fi only) waits.
func SystemState() model.SystemState {
	var st model.SystemState
	st.Network.Status, st.Network.Interface = "satisfied", "wifi"
	st.Network.SSID = model.Ptr("Café Wi-Fi")
	st.Power.BatteryPercent = model.Ptr(82)
	st.Disk.FreeBytes = 312 << 30
	return st
}

// Seed writes demo accounts, jobs, history, logs and actions into an
// empty data directory. It is a no-op when jobs already exist.
func Seed(p paths.Paths) error {
	cfg, err := config.Open(p.ConfigDir)
	if err != nil {
		return err
	}
	if len(cfg.Jobs()) > 0 {
		return nil
	}
	db, err := store.Open(p.DataDir)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	now := time.Now().UTC()
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	tb := int64(1) << 40

	accs := []model.Account{
		{ID: AccWork, Provider: "drive", Name: "Work", Status: model.AccountOK, CreatedAt: ago(90 * 24 * time.Hour),
			Quota: &model.Quota{Total: model.Ptr(2 * tb), Used: model.Ptr(tb * 121 / 100), Free: model.Ptr(tb * 79 / 100), Trashed: model.Ptr(int64(3_200_000_000))}},
		{ID: AccPersonal, Provider: "dropbox", Name: "Personal", Status: model.AccountNeedsAuth, Error: model.Ptr("token expired: reconnect to continue"), CreatedAt: ago(60 * 24 * time.Hour),
			Quota: &model.Quota{Total: model.Ptr(2 * tb), Used: model.Ptr(int64(640) << 30), Free: model.Ptr(2*tb - int64(640)<<30)}},
		{ID: AccBackups, Provider: "s3", Name: "Backups", Status: model.AccountOK, CreatedAt: ago(30 * 24 * time.Hour)},
		{ID: AccNAS, Provider: "sftp", Name: "NAS", Status: model.AccountOK, CreatedAt: ago(20 * 24 * time.Hour),
			Quota: &model.Quota{Total: model.Ptr(8 * tb), Used: model.Ptr(5 * tb), Free: model.Ptr(3 * tb)}},
	}
	for _, a := range accs {
		a.Remote = "pd_" + a.ID
		if err := cfg.PutAccount(a); err != nil {
			return err
		}
	}

	st := cfg.Settings()
	mk := func(id, name, local, acc, remote, dir, del, conflict string, created time.Time) model.Job {
		j := config.NewJobDefaults(st)
		j.ID, j.Name, j.LocalPath, j.AccountID, j.RemotePath = id, name, local, acc, remote
		j.Direction, j.DeletePolicy, j.ConflictPolicy = dir, del, conflict
		j.CreatedAt, j.UpdatedAt = created, created
		j.Filters.Presets = []string{"vcs", "ide", "deps", "build", "osjunk"}
		return j
	}
	projects := mk(JobProjects, "Projects", HomeUser+"/Projects", AccWork, "Backups/Projects", model.DirUpload, model.DeleteArchive, model.ConflictNewer, ago(40*24*time.Hour))
	projects.Triggers.OnChange, projects.Triggers.DebounceSec = true, 10
	docs := mk(JobDocuments, "Documents", HomeUser+"/Documents", AccWork, "Documents", model.DirTwoWay, model.DeleteArchive, model.ConflictAsk, ago(35*24*time.Hour))
	docs.Triggers.IntervalMin = model.Ptr(30)
	site := mk(JobWebsite, "Website backups", HomeUser+"/Sites", AccBackups, "pigment-backups/sites", model.DirUpload, model.DeleteMirror, model.ConflictNewer, ago(25*24*time.Hour))
	site.Triggers.Daily = model.Ptr("03:00")
	nas := mk(JobNAS, "Photo archive → NAS", HomeUser+"/Pictures/Exports", AccNAS, "volume1/photos", model.DirUpload, model.DeleteNever, model.ConflictNewer, ago(15*24*time.Hour))
	nas.Network.SSIDAllow = []string{"Home"}
	nas.Triggers.Weekly = &model.Weekly{Day: 7, Time: "21:00"}
	nas.Limits.BwUpKBps = model.Ptr(20480)
	notes := mk(JobNotes, "Notes", HomeUser+"/Notes", AccPersonal, "Notes", model.DirTwoWay, model.DeleteArchive, model.ConflictKeepBoth, ago(2*time.Hour))
	notes.Triggers.OnChange = true
	for _, j := range []model.Job{projects, docs, site, nas, notes} {
		if err := cfg.PutJob(j); err != nil {
			return err
		}
		_ = cfg.UpdateRuntime(j.ID, func(r *config.JobRuntime) {
			r.PreviewDone = j.ID != JobNotes
			r.NeedsBaseline = j.ID == JobNotes
			r.LastFullReconcile = ago(2 * time.Hour).Format(time.RFC3339)
		})
	}

	ctx := context.Background()
	run := func(job, id string, start time.Time, dur time.Duration, ok bool, bytes, files, dels, conflicts int64, errMsg string) {
		end := start.Add(dur)
		r := model.RunSummary{ID: id, StartedAt: start, EndedAt: &end, OK: ok, Bytes: bytes, Files: files, Deletes: dels, Conflicts: conflicts}
		if errMsg != "" {
			r.Error = model.Ptr(errMsg)
		}
		_ = db.PutRun(ctx, job, r)
	}
	run(JobProjects, "run_p0a1b2", ago(26*time.Hour), 4*time.Minute, true, 2_140_000_000, 512, 3, 0, "")
	run(JobProjects, "run_p0c3d4", ago(3*time.Hour), 52*time.Second, true, 48_200_000, 19, 0, 0, "")
	run(JobDocuments, "run_d0a1b2", ago(5*time.Hour), 31*time.Second, true, 12_400_000, 8, 1, 0, "")
	run(JobDocuments, "run_d0c3d4", ago(25*time.Minute), 18*time.Second, true, 3_100_000, 3, 0, 1, "")
	run(JobWebsite, "run_s0a1b2", ago(2*24*time.Hour), 3*time.Minute, true, 920_000_000, 1410, 12, 0, "")
	run(JobWebsite, "run_s0c3d4", ago(9*time.Hour), 6*time.Second, false, 0, 0, 0, 0, "too many deletes: 1311 of 1410 files (92%) would be deleted, limit is 25%")
	run(JobNAS, "run_n0a1b2", ago(6*24*time.Hour), 11*time.Minute, true, 6_800_000_000, 842, 0, 0, "")

	act := func(a model.Action) { _ = db.PutAction(ctx, a) }
	act(model.Action{ID: "act_conf01", JobID: model.Ptr(JobDocuments), Kind: model.ActConflict, Severity: "warning",
		Title:   "Edited on both sides: Proposal Q4.docx",
		Message: `"Clients/Acme/Proposal Q4.docx" changed on this computer and in the cloud since the last sync of "Documents". Both versions were kept; choose which one wins.`,
		Path:    model.Ptr("Clients/Acme/Proposal Q4.docx"), CreatedAt: ago(25 * time.Minute),
		Choices: []model.Choice{{ID: "keepLocal", Label: "Keep this Mac's version"}, {ID: "keepRemote", Label: "Keep the cloud version"}, {ID: "keepBoth", Label: "Keep both"}},
		Data:    map[string]string{"path": "Clients/Acme/Proposal Q4.docx", "localCopy": "Clients/Acme/Proposal Q4.conflict-local1.docx", "remoteCopy": "Clients/Acme/Proposal Q4.conflict-remote1.docx"}})
	act(model.Action{ID: "act_auth02", JobID: model.Ptr(JobNotes), Kind: model.ActAuthExpired, Severity: "error",
		Title: "Reconnect Personal", Message: `The sign-in for "Personal" (Dropbox) expired, so "Notes" cannot sync.`, CreatedAt: ago(70 * time.Minute),
		Choices: []model.Choice{{ID: "reconnect", Label: "Reconnect"}, {ID: "dismiss", Label: "Dismiss"}}, Data: map[string]string{"accountId": AccPersonal}})
	act(model.Action{ID: "act_mdel03", JobID: model.Ptr(JobWebsite), Kind: model.ActMaxDeleteAbort, Severity: "warning",
		Title:     `"Website backups" stopped to protect your files`,
		Message:   "too many deletes: 1311 of 1410 files (92%) would be deleted, limit is 25%. Nothing was deleted. Check that the folder is not missing or emptied by mistake, then choose Run anyway.",
		CreatedAt: ago(9 * time.Hour), Choices: []model.Choice{{ID: "runAnyway", Label: "Run anyway"}, {ID: "dismiss", Label: "Dismiss"}}})

	type ll struct {
		ago   time.Duration
		level string
		job   string
		run   string
		msg   string
		path  string
	}
	lines := []ll{
		{26 * time.Hour, "notice", "", "", "pdrcloned started (pid 412, darwin/arm64)", ""},
		{26 * time.Hour, "notice", JobProjects, "run_p0a1b2", `Started full sync of "Projects" (schedule)`, ""},
		{26 * time.Hour, "info", JobProjects, "run_p0a1b2", "Copied (new)", "pigment-site/assets/hero.webp"},
		{26 * time.Hour, "info", JobProjects, "run_p0a1b2", "Moved into archive .pdrclone-archive/" + ago(26*time.Hour).Format("2006-01-02"), "old/landing-v1.fig"},
		{26 * time.Hour, "notice", JobProjects, "run_p0a1b2", `Finished "Projects": 512 file(s), 2.0 GiB, 3 deleted, 0 conflict(s) in 4m0s`, ""},
		{9 * time.Hour, "notice", JobWebsite, "run_s0c3d4", `Started full sync of "Website backups" (schedule)`, ""},
		{9 * time.Hour, "error", JobWebsite, "run_s0c3d4", `Failed "Website backups": too many deletes: 1311 of 1410 files (92%) would be deleted, limit is 25%`, ""},
		{6 * time.Hour, "notice", "", "", "Bandwidth limit set to 20Mi:off (job Photo archive → NAS)", ""},
		{5 * time.Hour, "notice", JobDocuments, "run_d0a1b2", `Started full sync of "Documents" (schedule)`, ""},
		{5 * time.Hour, "info", JobDocuments, "run_d0a1b2", "Copied (replaced existing)", "Finance/2026 budget.xlsx"},
		{5 * time.Hour, "info", JobDocuments, "run_d0a1b2", "Moved into archive", "Drafts/old outline.md"},
		{5 * time.Hour, "notice", JobDocuments, "run_d0a1b2", `Finished "Documents": 8 file(s), 11.8 MiB, 1 deleted, 0 conflict(s) in 31s`, ""},
		{3 * time.Hour, "notice", JobProjects, "run_p0c3d4", `Started quick sync of 19 changed file(s) of "Projects" (files changed)`, ""},
		{3 * time.Hour, "debug", JobProjects, "run_p0c3d4", "Excluded (Path Filter)", "rclone-app/.git/index"},
		{3 * time.Hour, "debug", JobProjects, "run_p0c3d4", "Excluded (Path Filter)", "pigment-site/node_modules/.package-lock.json"},
		{3 * time.Hour, "debug", JobProjects, "run_p0c3d4", "Excluded (Path Filter)", "rclone-app/.claude/settings.local.json"},
		{3 * time.Hour, "info", JobProjects, "run_p0c3d4", "Copied (new)", "rclone-app/core/internal/engine/run.go"},
		{3 * time.Hour, "info", JobProjects, "run_p0c3d4", "Copied (replaced existing)", "rclone-app/README.md"},
		{3 * time.Hour, "notice", JobProjects, "run_p0c3d4", `Finished "Projects": 19 file(s), 46.0 MiB, 0 deleted, 0 conflict(s) in 52s`, ""},
		{2 * time.Hour, "notice", JobNotes, "", `Job "Notes" created (twoWay, /Users/alex/Notes → Notes)`, ""},
		{75 * time.Minute, "warn", JobNotes, "", "Dropbox: token expired, refresh failed: invalid_grant", ""},
		{70 * time.Minute, "error", JobNotes, "", "Sign-in expired: reconnect the account", ""},
		{40 * time.Minute, "notice", JobNAS, "", `Waiting for an allowed Wi-Fi: connected to "Café Wi-Fi"`, ""},
		{26 * time.Minute, "notice", JobDocuments, "run_d0c3d4", `Started full sync of "Documents" (schedule)`, ""},
		{25 * time.Minute, "warn", JobDocuments, "run_d0c3d4", "New or changed in both paths", "Clients/Acme/Proposal Q4.docx"},
		{25 * time.Minute, "info", JobDocuments, "run_d0c3d4", "Renamed conflict copies (.conflict-local1 / .conflict-remote1)", "Clients/Acme/Proposal Q4.docx"},
		{25 * time.Minute, "notice", JobDocuments, "run_d0c3d4", `Finished "Documents": 3 file(s), 3.0 MiB, 0 deleted, 1 conflict(s) in 18s`, ""},
		{12 * time.Minute, "info", "", "", "Quota refreshed for Work (Google Drive): 1.2 TiB of 2.0 TiB used", ""},
		{8 * time.Minute, "notice", JobProjects, "", "12 changes detected in /Users/alex/Projects", ""},
		{2 * time.Minute, "info", JobWebsite, "", "Next run tonight at 03:00", ""},
	}
	for _, l := range lines {
		line := model.LogLine{TS: ago(l.ago), Level: l.level, Msg: l.msg}
		if l.job != "" {
			line.JobID = model.Ptr(l.job)
		}
		if l.run != "" {
			line.RunID = model.Ptr(l.run)
		}
		if l.path != "" {
			line.Path = model.Ptr(l.path)
		}
		db.AddLog(line)
	}
	db.Flush()
	return nil
}
