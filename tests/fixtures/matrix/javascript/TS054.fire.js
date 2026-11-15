async function run(value) {
    console.assert(value > 0);
    await work(value);
}
