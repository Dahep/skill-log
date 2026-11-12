package store

import (
	"database/sql"
	"errors"
	"strings"

	"github.com/Dahep/skill-log/internal/format"
	"github.com/Dahep/skill-log/internal/marker"
)

// Invocation is one invocation row and its problems.
//
// The column order is the schema's, and it is also the order JSON exposes:
// one flat object whose fields a reader can take without a guess.
type Invocation struct {
	ID         int64
	TS         string
	Skill      string
	Harness    string
	Session    string
	Parent     string
	Model      string
	Repo       string
	Worktree   string
	Project    string
	T3Thread   string
	Machine    string
	Fix        string
	ResolvedAt string
	Problems   []string
}

// Marker is the row's marker: `machine#id`.
//
// A row that has not been written has no id yet, so it has no marker either:
// the --dry-run preview must not claim a row that does not exist.
func (i Invocation) Marker() string {
	if i.ID == 0 {
		return ""
	}
	return marker.Format(i.Machine, i.ID)
}

// Filters is what one read of the store selects. An empty string means the
// filter is not given; Run names a run rather than a column, and matches the
// session, the T3 thread or the parent.
type Filters struct {
	Skill      string
	Machine    string
	Harness    string
	Repo       string
	Run        string
	Unresolved bool
	Limit      int
}

func filterClause(filters Filters) (string, []any) {
	var clauses []string
	var marks []any
	if filters.Skill != "" {
		clauses = append(clauses, "skill = ?")
		marks = append(marks, filters.Skill)
	}
	if filters.Machine != "" {
		clauses = append(clauses, "machine = ?")
		marks = append(marks, filters.Machine)
	}
	if filters.Harness != "" {
		clauses = append(clauses, "harness = ?")
		marks = append(marks, filters.Harness)
	}
	if filters.Repo != "" {
		clauses = append(clauses, "repo = ?")
		marks = append(marks, filters.Repo)
	}
	if filters.Run != "" {
		clauses = append(clauses, "(session = ? OR t3_thread = ? OR parent = ?)")
		marks = append(marks, filters.Run, filters.Run, filters.Run)
	}
	if filters.Unresolved {
		clauses = append(clauses, "fix = ''")
	}
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), marks
}

// ReadInvocation reads one invocation row and its problems.
func (s *Store) ReadInvocation(id int64) (*Invocation, error) {
	row := s.db.QueryRow(invocationSelect+" WHERE id = ?", id)
	invocation, err := scanInvocation(row)
	if err != nil {
		return nil, err
	}
	if invocation == nil {
		return nil, nil
	}
	problems, err := s.problemsFor(id)
	if err != nil {
		return nil, err
	}
	invocation.Problems = problems
	return invocation, nil
}

// Rows reads the invocation rows the filters select, newest first.
//
// The ordering is `datetime(ts) DESC, id DESC`: datetime() normalizes each
// row's ISO stamp (rows carry their writer's own UTC offset) so the rows sort
// by when the run happened, not by when it was written. A limit of zero means
// every matching row.
func (s *Store) Rows(filters Filters) ([]Invocation, error) {
	clause, marks := filterClause(filters)
	query := invocationSelect + clause + " ORDER BY datetime(ts) DESC, id DESC"
	if filters.Limit > 0 {
		query += " LIMIT ?"
		marks = append(marks, filters.Limit)
	}
	rows, err := s.db.Query(query, marks...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Invocation
	for rows.Next() {
		invocation, err := scanInvocation(rows)
		if err != nil {
			return nil, err
		}
		if invocation == nil {
			continue
		}
		problems, err := s.problemsFor(invocation.ID)
		if err != nil {
			return nil, err
		}
		invocation.Problems = problems
		out = append(out, *invocation)
	}
	return out, rows.Err()
}

// scanner is the shape *sql.Row and *sql.Rows share.
type scanner interface {
	Scan(dest ...any) error
}

func scanInvocation(row scanner) (*Invocation, error) {
	var invocation Invocation
	err := row.Scan(
		&invocation.ID, &invocation.TS, &invocation.Skill, &invocation.Harness,
		&invocation.Session, &invocation.Parent, &invocation.Model,
		&invocation.Repo, &invocation.Worktree, &invocation.Project,
		&invocation.T3Thread, &invocation.Machine, &invocation.Fix,
		&invocation.ResolvedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &invocation, nil
}

func (s *Store) problemsFor(id int64) ([]string, error) {
	rows, err := s.db.Query(
		"SELECT problem FROM problems WHERE invocation_id = ? ORDER BY ordinal", id,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var problems []string
	for rows.Next() {
		var problem string
		if err := rows.Scan(&problem); err != nil {
			return nil, err
		}
		problems = append(problems, format.Sanitize(problem))
	}
	return problems, rows.Err()
}

// GroupCount is one line of the stats table: a group's key and its four
// counts. WithProblems counts invocations with at least one problem, and
// Problems counts problem rows: a run with two findings is one run and two
// problems.
type GroupCount struct {
	Key          string
	Invocations  int64
	WithProblems int64
	Problems     int64
	Resolved     int64
}

// GroupColumns is the columns a count may be grouped by, default first.
func GroupColumns() []string {
	return []string{"skill", "harness", "model", "repo", "worktree", "machine", "project"}
}

// IsGroupColumn reports whether name is one of the columns stats may group
// by. The one allow-list: no caller can put a column name into SQL text
// without having been through this check.
func IsGroupColumn(name string) bool {
	for _, column := range GroupColumns() {
		if column == name {
			return true
		}
	}
	return false
}

// GroupCounts counts the invocations and problems per value of column.
//
// COUNT(DISTINCT i.id) is the denominator and the only honest count: the LEFT
// JOIN produces one line per problem, so COUNT(*) would count problems. The
// join rather than a sub-query keeps a run with no problems visible, with
// zeroes.
func (s *Store) GroupCounts(column, skill string) ([]GroupCount, error) {
	if !IsGroupColumn(column) {
		return nil, errNotGroupable(column)
	}
	query := "SELECT i." + column + " AS group_key," +
		" COUNT(DISTINCT i.id)," +
		" COUNT(DISTINCT p.invocation_id)," +
		" COUNT(p.ordinal)," +
		" COUNT(DISTINCT CASE WHEN i.fix <> '' THEN i.id END)" +
		" FROM invocations i" +
		" LEFT JOIN problems p ON p.invocation_id = i.id"
	var marks []any
	if skill != "" {
		query += " WHERE i.skill = ?"
		marks = append(marks, skill)
	}
	query += " GROUP BY i." + column + " ORDER BY i." + column
	rows, err := s.db.Query(query, marks...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var groups []GroupCount
	for rows.Next() {
		var group GroupCount
		if err := rows.Scan(
			&group.Key, &group.Invocations, &group.WithProblems,
			&group.Problems, &group.Resolved,
		); err != nil {
			return nil, err
		}
		groups = append(groups, group)
	}
	return groups, rows.Err()
}

type notGroupable string

func (e notGroupable) Error() string      { return "not a groupable column: " + string(e) }
func errNotGroupable(column string) error { return notGroupable(column) }

// ResolutionRow is the columns a merged scan needs from one invocation row.
// Logged is the row's timestamp in epoch seconds, read by SQLite so the
// comparison against a commit time needs no second ISO parser.
type ResolutionRow struct {
	ID      int64
	Machine string
	Fix     string
	Logged  int64
}

// ResolutionRows reads every row's id, machine, fix and logged-at instant.
func (s *Store) ResolutionRows() ([]ResolutionRow, error) {
	rows, err := s.db.Query(
		"SELECT id, machine, fix," +
			" COALESCE(CAST(strftime('%s', ts) AS INTEGER), 0)" +
			" FROM invocations",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ResolutionRow
	for rows.Next() {
		var item ResolutionRow
		if err := rows.Scan(&item.ID, &item.Machine, &item.Fix, &item.Logged); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}
