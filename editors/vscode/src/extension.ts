import * as vscode from 'vscode';
import {
    DidChangeConfigurationNotification,
    LanguageClient,
    LanguageClientOptions,
    RevealOutputChannelOn,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    context.subscriptions.push(
        vscode.commands.registerCommand('tigerstyle.restart', async () => {
            await stop();
            await start(context);
        }),
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('tigerstyle.printDebugInformation', async () => {
            await client?.sendRequest('workspace/executeCommand', {
                command: 'tigerstyle.printDebugInformation',
                arguments: [],
            });
        }),
    );

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(async (event) => {
            if (!event.affectsConfiguration('tigerstyle')) {
                return;
            }

            if (restarted(event)) {
                await stop();
                await start(context);

                return;
            }

            await client?.sendNotification(DidChangeConfigurationNotification.type, {
                settings: null,
            });
        }),
    );

    await start(context);
}

export async function deactivate(): Promise<void> {
    await stop();
}

async function start(context: vscode.ExtensionContext): Promise<void> {
    const settings = vscode.workspace.getConfiguration('tigerstyle');

    if (!settings.get<boolean>('enable', true)) {
        return;
    }

    const command = settings.get<string>('path', 'tigerstyle-lsp');
    const languages = settings.get<string[]>('languages', ['go', 'python', 'rust', 'zig']);

    const server: ServerOptions = {
        command,
        args: ['server', ...argumentsOf(settings)],
        transport: TransportKind.stdio,
    };

    const options: LanguageClientOptions = {
        documentSelector: languages.map((language) => ({ scheme: 'file', language })),
        initializationOptions: {
            logFile: settings.get<string>('logFile', ''),
            logLevel: settings.get<string>('logLevel', 'info'),
        },
        revealOutputChannelOn: revealOf(settings.get<string>('showNotifications', 'onError')),
        synchronize: {
            fileEvents: [
                vscode.workspace.createFileSystemWatcher('**/tigerstyle.toml'),
                vscode.workspace.createFileSystemWatcher('**/.tigerstyle.toml'),
            ],
        },
    };

    client = new LanguageClient('tigerstyle-lsp', 'TigerStyle LSP', server, options);

    context.subscriptions.push(client);

    await client.start();
}

async function stop(): Promise<void> {
    if (client === undefined) {
        return;
    }

    await client.stop();

    client = undefined;
}

function restarted(event: vscode.ConfigurationChangeEvent): boolean {
    const restarting = [
        'tigerstyle.arguments',
        'tigerstyle.configPath',
        'tigerstyle.enable',
        'tigerstyle.isolated',
        'tigerstyle.languages',
        'tigerstyle.logFile',
        'tigerstyle.logLevel',
        'tigerstyle.path',
        'tigerstyle.showNotifications',
    ];

    return restarting.some((name) => event.affectsConfiguration(name));
}

function revealOf(named: string): RevealOutputChannelOn {
    if (named === 'off') {
        return RevealOutputChannelOn.Never;
    }

    if (named === 'always') {
        return RevealOutputChannelOn.Info;
    }

    return RevealOutputChannelOn.Error;
}

function argumentsOf(settings: vscode.WorkspaceConfiguration): string[] {
    const passed: string[] = [];
    const config = settings.get<string>('configPath', '');

    if (config.length > 0) {
        passed.push('--config', config);
    }

    if (settings.get<boolean>('isolated', false)) {
        passed.push('--isolated');
    }

    return [...passed, ...settings.get<string[]>('arguments', [])];
}
