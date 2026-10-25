type Handler = (value: number) => void;

function run(handler: Handler, name: string): void {
    handler(name.length);
}
