/*************************************************************************
 * ModernUO                                                              *
 * Copyright 2019-2026 - ModernUO Development Team                       *
 * Email: hi@modernuo.com                                                *
 * File: AssemblyHandler.cs                                              *
 *                                                                       *
 * This program is free software: you can redistribute it and/or modify  *
 * it under the terms of the GNU General Public License as published by  *
 * the Free Software Foundation, either version 3 of the License, or     *
 * (at your option) any later version.                                   *
 *                                                                       *
 * You should have received a copy of the GNU General Public License     *
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *
 *************************************************************************/

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;

namespace Server;

public static class AssemblyHandler
{
    private static readonly Dictionary<Assembly, TypeCache> m_TypeCaches = new();
    private static TypeCache m_NullCache;

    public static Assembly[] Assemblies { get; set; }

    internal static Assembly AssemblyResolver(object sender, ResolveEventArgs args)
    {
        var assemblyName = new AssemblyName(args.Name);
        return LoadAssemblyByAssemblyName(assemblyName);
    }

    internal static Assembly AssemblyResolver(AssemblyLoadContext context, AssemblyName assemblyName) =>
        LoadAssemblyByAssemblyName(assemblyName);

    private static void EnsureAssemblyDirectories()
    {
        if (ServerConfiguration.AssemblyDirectories.Count == 0)
        {
            ServerConfiguration.AssemblyDirectories.Add("./Assemblies");
            ServerConfiguration.Save();
        }
    }

    public static Assembly LoadAssemblyByAssemblyName(AssemblyName assemblyName)
    {
        if (assemblyName?.Name == null)
        {
            return null;
        }

        var loadedAssembly = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(
            assembly => string.Equals(assembly?.GetName().Name, assemblyName.Name, StringComparison.OrdinalIgnoreCase)
        );

        if (loadedAssembly != null)
        {
            return loadedAssembly;
        }

        var fullName = assemblyName.FullName;
        var fileName = $"{assemblyName.Name}.dll";

        EnsureAssemblyDirectories();
        var assemblyDirectories = ServerConfiguration.AssemblyDirectories;

        Assembly assembly = null;

        foreach (var assemblyDir in assemblyDirectories)
        {
            var assemblyPath = PathUtility.GetFullPath(Path.Combine(assemblyDir, fileName), Core.BaseDirectory);
            if (File.Exists(assemblyPath))
            {
                var assemblyNameCheck = AssemblyName.GetAssemblyName(assemblyPath);
                if (assemblyNameCheck.FullName == fullName)
                {
                    assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(assemblyPath);
                    break;
                }

                if (string.Equals(assemblyNameCheck.Name, assemblyName.Name, StringComparison.OrdinalIgnoreCase))
                {
                    Console.WriteLine(
                        "Warning: Resolving assembly {0} using simple-name match {1}",
                        fullName,
                        assemblyNameCheck.FullName
                    );

                    assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(assemblyPath);
                    break;
                }
            }
        }

        // This forces the type caching to be generated.
        // We need this for world loading to find types by hash.
        GetTypeCache(assembly);

        return assembly;
    }

    public static Assembly LoadAssemblyByFileName(string assemblyFile)
    {
        EnsureAssemblyDirectories();
        var assemblyDirectories = ServerConfiguration.AssemblyDirectories;

        foreach (var assemblyDir in assemblyDirectories)
        {
            var assemblyPath = Path.Combine(assemblyDir, assemblyFile);
            if (File.Exists(assemblyPath))
            {
                return AssemblyLoadContext.Default.LoadFromAssemblyPath(assemblyPath);
            }
        }

        return null;
    }

    public static void LoadAssemblies(string[] files)
    {
        var assemblies = new Assembly[files.Length];

        for (var i = 0; i < files.Length; i++)
        {
            var assemblyFile = files[i];
            var assembly = LoadAssemblyByFileName(assemblyFile);
            if (assembly == null)
            {
                throw new FileNotFoundException(
                    $"Could not load file or assembly {assemblyFile}. The system cannot find the file specified. Review the assemblyDirectories field in {ServerConfiguration.ConfigurationFilePath}",
                    assemblyFile
                );
            }

            assemblies[i] = assembly;
        }

        Assemblies = assemblies;
    }

    public static void Invoke(string method)
    {
        var invoke = new List<MethodInfo>();

        Core.Assembly.AddMethods(method, invoke);

        for (var i = 0; i < Assemblies.Length; i++)
        {
            Assemblies[i].AddMethods(method, invoke);
        }

        invoke.Sort(new CallPriorityComparer());

        for (var i = 0; i < invoke.Count; ++i)
        {
            if (ShouldSkipInvocation(method, invoke[i]))
            {
                continue;
            }

            invoke[i].Invoke(null, null);
        }
    }

    public static bool IsUoContentManagedByCore() =>
        Assemblies?.Any(a => string.Equals(a?.GetName().Name, "UOContent", StringComparison.OrdinalIgnoreCase)) == true;

    public static bool ShouldSkipUoContentInvocation(string methodName, MethodInfo method)
    {
        if (method.DeclaringType?.Assembly.GetName().Name is not { } assemblyName ||
            !string.Equals(assemblyName, "UOContent", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (HasLoadedOverride(method.DeclaringType))
        {
            return true;
        }

        return methodName switch
        {
            "Configure" => ShouldSkipUoContentConfigure(method),
            "Initialize" => ShouldSkipUoContentInitialize(method),
            _ => false
        };
    }

    private static bool ShouldSkipInvocation(string methodName, MethodInfo method) =>
        ShouldSkipUoContentInvocation(methodName, method);

    private static bool ShouldSkipUoContentConfigure(MethodInfo method)
    {
        var fullName = method.DeclaringType?.FullName;
        var @namespace = method.DeclaringType?.Namespace;

        if (string.Equals(fullName, "Server.PoisonKinds", StringComparison.Ordinal))
        {
            return true;
        }

        if (NamespaceStartsWith(@namespace, "Server.Accounting") ||
            NamespaceStartsWith(@namespace, "Server.Commands") ||
            NamespaceStartsWith(@namespace, "Server.Commands.Generic") ||
            NamespaceStartsWith(@namespace, "Server.Assistants") ||
            NamespaceStartsWith(@namespace, "Server.Engines.Help") ||
            NamespaceStartsWith(@namespace, "Server.Engines.Spawners"))
        {
            return true;
        }

        return string.Equals(fullName, "Server.Misc.AccountHandler", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.AccountPrompt", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Engines.Spawners.ImportSpawnersCommand", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.Guild", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.HardwareInfo", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.Paperdoll", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Systems.JailSystem.JailSystem", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Network.AssistantProtocol", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Network.MapUO", StringComparison.Ordinal);
    }

    private static bool ShouldSkipUoContentInitialize(MethodInfo method)
    {
        var fullName = method.DeclaringType?.FullName;
        var @namespace = method.DeclaringType?.Namespace;

        if (NamespaceStartsWith(@namespace, "Server.Accounting") ||
            NamespaceStartsWith(@namespace, "Server.Commands") ||
            NamespaceStartsWith(@namespace, "Server.Commands.Generic") ||
            NamespaceStartsWith(@namespace, "Server.Assistants") ||
            NamespaceStartsWith(@namespace, "Server.Engines.Help") ||
            NamespaceStartsWith(@namespace, "Server.Engines.Spawners"))
        {
            return true;
        }

        return string.Equals(fullName, "Server.Misc.AccountHandler", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.AccountPrompt", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Engines.Spawners.ImportSpawnersCommand", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.Guild", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.HardwareInfo", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Misc.Paperdoll", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Systems.JailSystem.JailSystem", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Mobiles.EscortDestinationInfo", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Network.AssistantProtocol", StringComparison.Ordinal) ||
               string.Equals(fullName, "Server.Network.MapUO", StringComparison.Ordinal);
    }

    private static bool NamespaceStartsWith(string @namespace, string prefix) =>
        @namespace?.StartsWith(prefix, StringComparison.Ordinal) == true;

    private static bool HasLoadedOverride(Type type)
    {
        var fullName = type.FullName;
        if (string.IsNullOrWhiteSpace(fullName) || Assemblies == null)
        {
            return false;
        }

        for (var i = 0; i < Assemblies.Length; i++)
        {
            var assembly = Assemblies[i];
            if (assembly == null || ReferenceEquals(assembly, type.Assembly))
            {
                continue;
            }

            if (!string.Equals(assembly.GetName().Name, "ZuluContent", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (assembly.GetType(fullName, throwOnError: false, ignoreCase: false) != null)
            {
                return true;
            }
        }

        return false;
    }

    private static void AddMethods(this Assembly assembly, string method, List<MethodInfo> list)
    {
        var types = GetLoadableTypes(assembly);

        for (var i = 0; i < types.Length; i++)
        {
            var m = types[i].GetMethod(method, BindingFlags.Static | BindingFlags.Public);
            if (m?.GetParameters().Length == 0)
            {
                list.Add(m);
            }
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static ulong GetTypeHash(Type type) => GetTypeHash(type.FullName);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static ulong GetTypeHash(string key) => key == null ? 0 : HashUtility.ComputeHash64(key);

    public static TypeCache GetTypeCache(Assembly asm)
    {
        if (asm == null)
        {
            return m_NullCache ??= new TypeCache(null);
        }

        if (m_TypeCaches.TryGetValue(asm, out var c))
        {
            return c;
        }

        return m_TypeCaches[asm] = new TypeCache(asm);
    }

    internal static Type[] GetLoadableTypes(Assembly assembly)
    {
        if (assembly == null)
        {
            return Type.EmptyTypes;
        }

        try
        {
            return assembly.GetTypes();
        }
        catch (ReflectionTypeLoadException ex)
        {
            Console.WriteLine(
                "Warning: Type scan partially skipped for assembly {0}: {1}",
                assembly.FullName,
                ex.Message
            );

            foreach (var loaderException in ex.LoaderExceptions.Where(exception => exception != null))
            {
                Console.WriteLine(loaderException);
            }

            return ex.Types.Where(type => type != null).ToArray();
        }
    }

    public static Type FindTypeByFullName(string name, bool ignoreCase = true) =>
        FindTypeByName(name, true, ignoreCase);

    public static Type FindTypeByName(string name, bool fullName = false, bool ignoreCase = true)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        for (var i = 0; i < Assemblies.Length; i++)
        {
            foreach (var type in GetTypeCache(Assemblies[i]).GetTypesByName(name, fullName, ignoreCase))
            {
                return type;
            }
        }

        foreach(var type in GetTypeCache(Core.Assembly).GetTypesByName(name, fullName, ignoreCase))
        {
            return type;
        }

        foreach (var assembly in GetSupplementalAssemblies())
        {
            foreach (var type in GetTypeCache(assembly).GetTypesByName(name, fullName, ignoreCase))
            {
                return type;
            }
        }

        return null;
    }

    public static Type FindTypeByHash(ulong hash)
    {
        for (var i = 0; i < Assemblies.Length; i++)
        {
            foreach (var type in GetTypeCache(Assemblies[i]).GetTypesByHash(hash, true, false))
            {
                return type;
            }
        }

        foreach(var type in GetTypeCache(Core.Assembly).GetTypesByHash(hash, true, false))
        {
            return type;
        }

        foreach (var assembly in GetSupplementalAssemblies())
        {
            foreach (var type in GetTypeCache(assembly).GetTypesByHash(hash, true, false))
            {
                return type;
            }
        }

        return null;
    }

    private static IEnumerable<Assembly> GetSupplementalAssemblies()
    {
        var loaded = AppDomain.CurrentDomain.GetAssemblies();

        for (var i = 0; i < loaded.Length; i++)
        {
            var assembly = loaded[i];

            if (assembly == null || assembly.IsDynamic || ReferenceEquals(assembly, Core.Assembly))
            {
                continue;
            }

            if (Assemblies != null && Array.IndexOf(Assemblies, assembly) >= 0)
            {
                continue;
            }

            yield return assembly;
        }
    }
}

public class TypeCache
{
#if DEBUG_TYPES
    private static ILogger logger = LogFactory.GetLogger(typeof(TypeCache));
#endif

    private readonly Dictionary<ulong, Type[]> _nameMap = [];
    private readonly Dictionary<ulong, Type[]> _nameMapInsensitive = [];
    private readonly Dictionary<ulong, Type[]> _fullNameMap = [];
    private readonly Dictionary<ulong, Type[]> _fullNameMapInsensitive = [];

    public TypeCache(Assembly asm)
    {
        Types = AssemblyHandler.GetLoadableTypes(asm);

        var nameMap = new Dictionary<string, HashSet<Type>>();
        var nameMapInsensitive = new Dictionary<string, HashSet<Type>>();
        var fullNameMap = new Dictionary<string, HashSet<Type>>();
        var fullNameMapInsensitive = new Dictionary<string, HashSet<Type>>();

        var aliasType = typeof(TypeAliasAttribute);
        for (var i = 0; i < Types.Length; i++)
        {
            var current = Types[i];
            addTypeToRefs(current, current.Name, current.FullName ?? "");
            if (current.GetCustomAttribute(aliasType, false) is TypeAliasAttribute alias)
            {
                for (var j = 0; j < alias.Aliases.Length; j++)
                {
                    var fullTypeName = alias.Aliases[j];
                    var typeName = fullTypeName[(fullTypeName.AsSpan().LastIndexOf('.') + 1)..];
                    addTypeToRefs(current, typeName, fullTypeName);
                }
            }
        }

        foreach (var (key, value) in nameMap)
        {
            _nameMap[HashUtility.ComputeHash64(key)] = value.ToArray();
        }

        foreach (var (key, value) in nameMapInsensitive)
        {
            _nameMapInsensitive[HashUtility.ComputeHash64(key)] = value.ToArray();
        }

        foreach (var (key, value) in fullNameMap)
        {
            var values = value.ToArray();
            _fullNameMap[HashUtility.ComputeHash64(key)] = values;
#if DEBUG_TYPES
            if (values.Length > 1)
            {
                for (var i = 0; i < values.Length; i++)
                {
                    var type = values[i];
                    logger.Warning(
                        "Duplicate type {Type} for {Name}.",
                        type,
                        key
                    );
                }
            }
#endif
        }

        foreach (var (key, value) in fullNameMapInsensitive)
        {
            var values = value.ToArray();
            _fullNameMapInsensitive[HashUtility.ComputeHash64(key)] = values;
#if DEBUG_TYPES
            if (values.Length > 1)
            {
                for (var i = 0; i < values.Length; i++)
                {
                    var type = values[i];
                    logger.Warning(
                        "Duplicate type {Type} for {Name}.",
                        type,
                        key
                    );
                }
            }
#endif
        }

        return;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        void addTypeToRefs(Type type, string typeName, string fullTypeName)
        {
            AddToRefs(type, typeName, nameMap);
            AddToRefs(type, typeName.ToLower(), nameMapInsensitive);
            AddToRefs(type, fullTypeName, fullNameMap);
            AddToRefs(type, fullTypeName.ToLower(), fullNameMapInsensitive);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void AddToRefs(Type type, string key, Dictionary<string, HashSet<Type>> map)
    {
        if (string.IsNullOrEmpty(key))
        {
            return;
        }

        if (map.TryGetValue(key, out var refs))
        {
            refs.Add(type);
        }
        else
        {
            refs = [type];
            map.Add(key, refs);
        }
    }

    public Type[] Types { get; }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public TypeEnumerator GetTypesByName(string name, bool full, bool ignoreCase) => new(name, this, full, ignoreCase);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public TypeEnumerator GetTypesByHash(ulong hash, bool full, bool ignoreCase) => new(hash, this, full, ignoreCase);

    public ref struct TypeEnumerator
    {
        private readonly Type[] _values;
        private int _index;
        private Type _current;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal TypeEnumerator(string name, TypeCache cache, bool full, bool ignoreCase)
            : this(HashUtility.ComputeHash64(ignoreCase ? name.ToLower() : name), cache, full, ignoreCase)
        {
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal TypeEnumerator(ulong hash, TypeCache cache, bool full, bool ignoreCase)
        {
            if (ignoreCase)
            {
                var map = full ? cache._fullNameMapInsensitive : cache._nameMapInsensitive;
                _values = map.TryGetValue(hash, out var values) ? values : [];
            }
            else
            {
                var map = full ? cache._fullNameMap : cache._nameMap;
                _values = map.TryGetValue(hash, out var values) ? values : [];
            }

            _index = 0;
            _current = default;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public TypeEnumerator GetEnumerator() => this;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool MoveNext()
        {
            if ((uint)_index < (uint)_values.Length)
            {
                _current = _values[_index++];
                return true;
            }

            return false;
        }

        public Type Current
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            get => _current;
        }
    }
}
