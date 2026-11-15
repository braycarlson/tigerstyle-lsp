package fixture

run :: proc(path: string) -> Error {
    handle, err := open(path)

    if err != nil {
        return err
    }

    return nil
}
