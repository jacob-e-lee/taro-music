// No phone needed: node tool/oracle.test.mjs. Checks the pure helpers and that the in-page scripts at least parse.
import assert from 'node:assert/strict';
import { CELLS, PAGE, AUDIT_JS, keyOf, knownKeys, knownNoise, pickCells } from './oracle.mjs';

assert.equal(keyOf('small', 'Home', 'button#x.a b|c]'), 'small:Home:button#x.a_b_c_');
assert.deepEqual([...knownKeys('- [ ] [F:small:Home:a] x\n- [x] [F:dead-tap:Library:b] y')], ['small:Home:a', 'dead-tap:Library:b']);
assert.ok(knownNoise("TypeError: Cannot read properties of undefined (reading 'menu')", "- 'menu' TypeError in YouTube js"));
assert.ok(!knownNoise("TypeError: Cannot read properties of undefined (reading 'foo')", "- 'menu' TypeError"));
const cov = { cells: Object.fromEntries(CELLS.slice(1).map(c => [c, 5])), shown: {} };
assert.deepEqual(pickCells(cov, 1), [CELLS[0]]);                 // least covered first
cov.cells[CELLS[0]] = 999;
assert.ok(!pickCells(cov, CELLS.length).includes(CELLS[0]));     // unreachable cells are skipped
new Function('return ' + PAGE);                                   // parse only: needs a document to run
new Function('return ' + AUDIT_JS);
console.log(`ok (${CELLS.length} cells)`);
