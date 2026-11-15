async function run(value: number) {
    console.assert(value > 0);
    await work(value);
}
