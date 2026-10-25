export function Greeting(props: { name: string; items: string[] }) {
    const name = props.name;

    return (
        <div className="row" title={name} aria-label="greeting">
            Hello {name} world
            {props.items.map((item) => (
                <span key={item}>{item}</span>
            ))}
        </div>
    );
}
