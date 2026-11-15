function outer() {
    const inner = () => {
        return 1;
    };

    return inner();
}
