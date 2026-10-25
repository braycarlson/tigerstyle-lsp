function run(path) {
    try {
        open(path);
    } catch (error) {
        report(error);
    }
}
