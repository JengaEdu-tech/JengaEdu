const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
function extractFunction(name) {
  const marker = `function ${name}(`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `${name} exists`);
  let brace = source.indexOf('{', start), depth = 0, quote = null, escaped = false;
  for (let i = brace; i < source.length; i++) {
    const ch = source[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') { quote = ch; continue; }
    if (ch === '{') depth++;
    if (ch === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`Could not extract ${name}`);
}

const context = {
  ttmLearnersForEntry: x => (x.learnerIds || []).map(String),
  teacherNameById: id => `Teacher ${id}`,
  String, Set
};
vm.runInNewContext(extractFunction('ttmConflictList'), context);

const lesson = (id, extra = {}) => ({ id, class: `Class ${id}`, subject: `Subject ${id}`, day: 'Monday', time: '08:00–08:40', ...extra });

test('detects a teacher double-booking', () => {
  const issues = context.ttmConflictList([lesson('a', { teacherId: 't1' }), lesson('b', { teacherId: 't1' })]);
  assert.ok(issues.some(x => x.type === 'Teacher'));
});

test('detects a room double-booking', () => {
  const issues = context.ttmConflictList([lesson('a', { room: 'Lab 1' }), lesson('b', { room: 'Lab 1' })]);
  assert.ok(issues.some(x => x.type === 'Room'));
});

test('detects learner overlap across teaching groups', () => {
  const issues = context.ttmConflictList([lesson('a', { groupId: 'g1', learnerIds: ['L1', 'L2'] }), lesson('b', { groupId: 'g2', learnerIds: ['L2', 'L3'] })]);
  assert.ok(issues.some(x => x.type === 'Learner'));
});

test('detects overlapping whole-class lessons', () => {
  const issues = context.ttmConflictList([lesson('a', { class: 'Grade 10 East' }), lesson('b', { class: 'Grade 10 East' })]);
  assert.ok(issues.some(x => x.type === 'Class'));
});

test('allows parallel groups with disjoint learner membership', () => {
  const issues = context.ttmConflictList([lesson('a', { groupId: 'g1', learnerIds: ['L1', 'L2'] }), lesson('b', { groupId: 'g2', learnerIds: ['L3', 'L4'] })]);
  assert.equal(issues.length, 0);
});

test('app includes versioning, lock-aware regeneration and editor actions', () => {
  assert.match(source, /function ttmSnapshot\(/);
  assert.match(source, /function ttmRestoreVersion\(/);
  assert.match(source, /function toggleTimetableLessonLock\(/);
  assert.match(source, /function moveTimetableLesson\(/);
  assert.match(source, /function ttmShowGroups\(/);
});


test('includes colourful report-style timetable print layout', () => {
  assert.match(source, /function timetablePrintGrid\(/);
  assert.match(source, /jenga-timetable-print/);
  assert.match(source, /background:#173b72/);
  assert.match(source, /function printTimetableDocument\(/);
  assert.match(source, /timetablePrintGrid\(c\)/);
});
