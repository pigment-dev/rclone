package engine

import "testing"

func TestComputerPaths(t *testing.T) {
	cases := []struct{ in, want string }{
		{"@computer:1AbC:My Mac", "pd_acc,root_folder_id=1AbC:"},
		{"@computer:1AbC:My Mac/Desktop/notes", "pd_acc,root_folder_id=1AbC:Desktop/notes"},
		{"Backups/Projects", "pd_acc:Backups/Projects"},
		{"/", "pd_acc:/"},
	}
	for _, c := range cases {
		if got := RemoteFs("pd_acc", c.in); got != c.want {
			t.Errorf("RemoteFs(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if _, _, ok := ParseComputerPath("@computer::x"); ok {
		t.Error("empty folder id must not parse")
	}
}
