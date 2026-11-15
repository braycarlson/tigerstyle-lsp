const commented = `${ /* ` } */ one() }`;
const lined = `${ two() // ` }
}`;
const quoted = `${ "}" }`;
const pattern = `${ /[}`]/.test("x") }`;
const divided = `${ one() / two() }`;
const dollar = $one($two) + `${ $three }`;
function one() { return 1; }
function two() { return 2; }
function $one(value) { return value; }
const $two = 2;
const $three = 3;
