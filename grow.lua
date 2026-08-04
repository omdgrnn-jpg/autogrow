local __DARKLUA_BUNDLE_MODULES

__DARKLUA_BUNDLE_MODULES = {
    cache = {},
    load = function(m)
        if not __DARKLUA_BUNDLE_MODULES.cache[m] then
            __DARKLUA_BUNDLE_MODULES.cache[m] = {
                c = __DARKLUA_BUNDLE_MODULES[m](),
            }
        end

        return __DARKLUA_BUNDLE_MODULES.cache[m].c
    end,
}

do
    function __DARKLUA_BUNDLE_MODULES.a()
        local function VIDE_ASSERT(msg)
            error(msg, 0)
        end

        return VIDE_ASSERT
    end
    function __DARKLUA_BUNDLE_MODULES.b()
        local function inline_test()
            return debug.info(1, 'n')
        end

        local is_O2 = inline_test() ~= 'inline_test'

        return {
            strict = not is_O2,
            batch = false,
        }
    end
    function __DARKLUA_BUNDLE_MODULES.c()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local flags = __DARKLUA_BUNDLE_MODULES.load('b')
        local scopes = {n = 0}

        local function ycall(fn, arg)
            local thread = coroutine.create(xpcall)

            local function efn(err)
                return debug.traceback(err, 3)
            end

            local resume_ok, run_ok, result = coroutine.resume(thread, fn, efn, arg)

            assert(resume_ok)

            if coroutine.status(thread) ~= 'dead' then
                return false, debug.traceback(thread, 'attempt to yield in reactive scope')
            end

            return run_ok, result
        end
        local function get_scope()
            return scopes[scopes.n]
        end
        local function assert_stable_scope()
            local scope = get_scope()

            if not scope then
                local caller_name = debug.info(2, 'n')

                return throw(string.format('cannot use %s() outside a stable or reactive scope', tostring(caller_name)))
            elseif scope.effect then
                throw(
[[cannot create a new reactive scope inside another reactive scope]])
            end

            return scope
        end
        local function push_child(parent, child)
            table.insert(parent, child)
            table.insert(child.parents, parent)
        end
        local function push_scope(node)
            local n = scopes.n + 1

            scopes.n = n
            scopes[n] = node
        end
        local function pop_scope()
            local n = scopes.n

            scopes.n = n - 1
            scopes[n] = nil
        end
        local function push_cleanup(node, cleanup)
            if node.cleanups then
                table.insert(node.cleanups, cleanup)
            else
                node.cleanups = {cleanup}
            end
        end
        local function flush_cleanups(node)
            if node.cleanups then
                for _, fn in next, node.cleanups do
                    local ok, err = pcall(fn)

                    if not ok then
                        throw(string.format('cleanup error: %s', tostring(err)))
                    end
                end

                table.clear(node.cleanups)
            end
        end
        local function find_and_swap_pop(t, v)
            local i = (table.find(t, v))
            local n = #t

            t[i] = t[n]
            t[n] = nil
        end
        local function unparent(node)
            local parents = node.parents

            for i, parent in parents do
                find_and_swap_pop(parent, node)

                parents[i] = nil
            end
        end
        local function destroy(node)
            flush_cleanups(node)
            unparent(node)

            if node.owner then
                find_and_swap_pop((node.owner.owned), node)

                node.owner = false
            end
            if node.owned then
                local owned = node.owned

                while owned[1] do
                    destroy(owned[1])
                end
            end
        end
        local function destroy_owned(node)
            if node.owned then
                local owned = node.owned

                while owned[1] do
                    destroy(owned[1])
                end
            end
        end

        local update_queue = {n = 0}

        local function evaluate_node(node)
            if flags.strict then
                local initial_value = node.cache

                for i = 1, 2 do
                    local cur_value = node.cache

                    flush_cleanups(node)
                    destroy_owned(node)
                    push_scope(node)

                    local ok, new_value = ycall((node.effect), cur_value)

                    pop_scope()

                    if not ok then
                        table.clear(update_queue)

                        update_queue.n = 0

                        throw(string.format('effect stacktrace:\n%s', tostring(new_value)))
                    end

                    node.cache = new_value
                end

                return initial_value ~= node.cache
            else
                local cur_value = node.cache

                flush_cleanups(node)
                destroy_owned(node)
                push_scope(node)

                local ok, new_value = pcall((node.effect), node.cache)

                pop_scope()

                if not ok then
                    table.clear(update_queue)

                    update_queue.n = 0

                    throw(string.format('effect stacktrace:\n%s\n', tostring(new_value)))
                end

                node.cache = new_value

                return cur_value ~= new_value
            end
        end
        local function queue_children_for_update(node)
            local i = update_queue.n

            while node[1] do
                i = i + 1
                update_queue[i] = node[1]

                unparent(node[1])
            end

            update_queue.n = i
        end
        local function get_update_queue_length()
            return update_queue.n
        end
        local function flush_update_queue(from)
            local i = from + 1

            while i <= update_queue.n do
                local node = update_queue[i]

                if node.owner and evaluate_node(node) then
                    queue_children_for_update(node)
                end

                update_queue[i] = false
                i = i + 1
            end

            update_queue.n = from
        end
        local function update_descendants(root)
            local n0 = update_queue.n

            queue_children_for_update(root)

            if flags.batch then
                return
            end

            local i = n0 + 1

            while i <= update_queue.n do
                local node = update_queue[i]

                if node.owner and evaluate_node(node) then
                    queue_children_for_update(node)
                end

                update_queue[i] = false
                i = i + 1
            end

            update_queue.n = n0
        end
        local function push_child_to_scope(node)
            local scope = get_scope()

            if scope and scope.effect then
                push_child(node, scope)
            end
        end
        local function create_node(owner, effect, value)
            local node = {
                cache = value,
                effect = effect,
                cleanups = false,
                context = false,
                owner = owner,
                owned = false,
                parents = {},
            }

            if owner then
                if owner.owned then
                    table.insert(owner.owned, node)
                else
                    owner.owned = {node}
                end
            end

            return node
        end
        local function create_source_node(value)
            return {cache = value}
        end
        local function get_children(node)
            return {
                unpack(node),
            }
        end
        local function set_context(node, key, value)
            if node.context then
                node.context[key] = value
            else
                node.context = {[key] = value}
            end
        end

        return table.freeze{
            push_scope = push_scope,
            pop_scope = pop_scope,
            evaluate_node = evaluate_node,
            get_scope = get_scope,
            assert_stable_scope = assert_stable_scope,
            push_cleanup = push_cleanup,
            destroy = destroy,
            flush_cleanups = flush_cleanups,
            push_child_to_scope = push_child_to_scope,
            update_descendants = update_descendants,
            push_child = push_child,
            create_node = create_node,
            create_source_node = create_source_node,
            get_children = get_children,
            flush_update_queue = flush_update_queue,
            get_update_queue_length = get_update_queue_length,
            set_context = set_context,
            scopes = scopes,
        }
    end
    function __DARKLUA_BUNDLE_MODULES.d()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local push_scope = graph.push_scope
        local pop_scope = graph.pop_scope
        local destroy = graph.destroy
        local refs = {}

        local function root(fn)
            local node = create_node(false, false, false)

            refs[node] = true

            local destroy = function()
                if not refs[node] then
                    throw'root already destroyed'
                end

                refs[node] = nil

                destroy(node)
            end

            push_scope(node)

            local function efn(err)
                return debug.traceback(err, 3)
            end

            local result = {
                xpcall(fn, efn, destroy),
            }

            pop_scope()

            if not result[1] then
                destroy()
                throw(string.format('error while running root():\n\n%s', tostring(result[2])))
            end

            return destroy, unpack(result, 2)
        end

        return root
    end
    function __DARKLUA_BUNDLE_MODULES.e()
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local assert_stable_scope = graph.assert_stable_scope
        local evaluate_node = graph.evaluate_node

        function create_implicit_effect(updater, binding)
            evaluate_node(create_node(assert_stable_scope(), updater, binding))
        end

        local function update_property_effect(p)
            ((p.instance))[p.property] = p.source()

            return p
        end
        local function update_parent_effect(p)
            p.instance.Parent = p.parent()

            return p
        end
        local function update_children_effect(p)
            local cur_children_set = p.cur_children_set
            local new_child_set = p.new_children_set
            local new_children = p.children()

            if type(new_children) ~= 'table' then
                new_children = {new_children}
            end

            local function process_child(child)
                if type(child) == 'table' then
                    for _, child in next, child do
                        process_child(child)
                    end
                else
                    if new_child_set[child] then
                        return
                    end

                    new_child_set[child] = true

                    if not cur_children_set[child] then
                        child.Parent = p.instance
                    else
                        cur_children_set[child] = nil
                    end
                end
            end

            process_child(new_children)

            for child in next, cur_children_set do
                child.Parent = nil
            end

            table.clear(cur_children_set)

            p.cur_children_set, p.new_children_set = new_child_set, cur_children_set

            return p
        end

        return {
            property = function(instance, property, source)
                return create_implicit_effect(update_property_effect, {
                    instance = instance,
                    property = property,
                    source = source,
                })
            end,
            parent = function(instance, parent)
                return create_implicit_effect(update_parent_effect, {
                    instance = instance,
                    parent = parent,
                })
            end,
            children = function(instance, children)
                return create_implicit_effect(update_children_effect, {
                    instance = instance,
                    cur_children_set = {},
                    new_children_set = {},
                    children = children,
                })
            end,
        }
    end
    function __DARKLUA_BUNDLE_MODULES.f()
        local ActionMT = table.freeze{}

        local function is_action(v)
            return getmetatable(v) == ActionMT
        end
        local function action(callback, priority)
            local a = {
                priority = priority or 1,
                callback = callback,
            }

            setmetatable(a, ActionMT)

            return table.freeze(a)
        end

        return function()
            return action, is_action
        end
    end
    function __DARKLUA_BUNDLE_MODULES.g()
        local flags = __DARKLUA_BUNDLE_MODULES.load('b')
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local bind = __DARKLUA_BUNDLE_MODULES.load('e')
        local _, is_action = __DARKLUA_BUNDLE_MODULES.load('f')()
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local free_caches

        local function borrow_caches()
            if free_caches then
                local caches = free_caches

                free_caches = nil

                return caches
            else
                return {
                    events = {},
                    actions = setmetatable({}, {
                        __index = function(self, i)
                            self[i] = {}

                            return self[i]
                        end,
                    }),
                    nested_debug = setmetatable({}, {
                        __index = function(self, i)
                            self[i] = {}

                            return self[i]
                        end,
                    }),
                    nested_stack = {},
                }
            end
        end
        local function return_caches(caches)
            free_caches = caches
        end

        local aggregates = {}

        for name, class in {
            CFrame = CFrame,
            Color3 = Color3,
            UDim = UDim,
            UDim2 = UDim2,
            Vector2 = Vector2,
            Vector3 = Vector3,
            Rect = Rect,
        }do
            aggregates[name] = class.new
        end

        local function apply(instance, properties)
            if not properties then
                throw(
[[attempt to call a constructor returned by create() with no properties]])
            end

            local strict = flags.strict
            local parent = properties.Parent
            local caches = borrow_caches()
            local events = caches.events
            local actions = caches.actions
            local nested_debug = caches.nested_debug
            local nested_stack = caches.nested_stack
            local depth = 1

            repeat
                for property, value in properties do
                    local __DARKLUA_CONTINUE_13 = false

                    repeat
                        if property == 'Parent' then
                            __DARKLUA_CONTINUE_13 = true

                            break
                        end
                        if type(property) == 'string' then
                            if strict then
                                if nested_debug[depth][property] then
                                    throw(string.format('duplicate property %s at depth %s', tostring(property), tostring(depth)))
                                end

                                nested_debug[depth][property] = true
                            end
                            if type(value) == 'table' then
                                local ctor = aggregates[typeof((instance)[property])]

                                if ctor == nil then
                                    throw(string.format('cannot aggregate type %s for property %s', tostring(typeof(value)), tostring(property)))
                                end

                                (instance)[property] = ctor(unpack(value))
                            elseif type(value) == 'function' then
                                if typeof((instance)[property]) == 'RBXScriptSignal' then
                                    events[property] = value
                                else
                                    bind.property(instance, property, value)
                                end
                            else
                                (instance)[property] = value
                            end
                        elseif type(property) == 'number' then
                            if type(value) == 'function' then
                                bind.children(instance, value)
                            elseif type(value) == 'table' then
                                if is_action(value) then
                                    table.insert(actions[(value).priority], ((value).callback))
                                else
                                    table.insert(nested_stack, value)
                                    table.insert(nested_stack, depth + 1)
                                end
                            else
                                (value).Parent = instance
                            end
                        end

                        __DARKLUA_CONTINUE_13 = true
                    until true

                    if not __DARKLUA_CONTINUE_13 then
                        break
                    end
                end

                depth = (table.remove(nested_stack))
                properties = (table.remove(nested_stack))
            until not properties

            for event, listener in next, events do
                (instance)[event]:Connect(listener)
            end
            for _, queued in next, actions do
                for _, callback in next, queued do
                    callback(instance)
                end
            end

            if parent then
                if type(parent) == 'function' then
                    bind.parent(instance, parent)
                else
                    instance.Parent = parent
                end
            end

            table.clear(events)

            for _, queued in next, actions do
                table.clear(queued)
            end

            if strict then
                table.clear(nested_debug)
            end

            table.clear(nested_stack)
            return_caches(caches)

            return instance
        end

        return apply
    end
    function __DARKLUA_BUNDLE_MODULES.h()
        local root = __DARKLUA_BUNDLE_MODULES.load('d')
        local apply = __DARKLUA_BUNDLE_MODULES.load('g')

        local function mount(component, target)
            return root(function()
                local result = component()

                if target then
                    apply(target, {result})
                end
            end)
        end

        return mount
    end
    function __DARKLUA_BUNDLE_MODULES.i()
        return {
            Part = {
                Material = Enum.Material.SmoothPlastic,
                Size = Vector3.new(1, 1, 1),
                Anchored = true,
            },
            BillboardGui = {
                ResetOnSpawn = false,
                ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            },
            CanvasGroup = nil,
            Frame = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
            },
            ImageButton = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
                AutoButtonColor = false,
            },
            ImageLabel = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
            },
            ScreenGui = {
                ResetOnSpawn = false,
                ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            },
            ScrollingFrame = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
                ScrollBarImageColor3 = Color3.new(0, 0, 0),
            },
            SurfaceGui = {
                ResetOnSpawn = false,
                ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
                PixelsPerStud = 50,
                SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
            },
            TextBox = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
                ClearTextOnFocus = false,
                Font = Enum.Font.SourceSans,
                Text = '',
                TextColor3 = Color3.new(0, 0, 0),
            },
            TextButton = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Font = Enum.Font.SourceSans,
                Text = '',
                TextColor3 = Color3.new(0, 0, 0),
            },
            TextLabel = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
                Font = Enum.Font.SourceSans,
                Text = '',
                TextColor3 = Color3.new(0, 0, 0),
            },
            UIListLayout = {
                SortOrder = Enum.SortOrder.LayoutOrder,
            },
            UIGridLayout = {
                SortOrder = Enum.SortOrder.LayoutOrder,
            },
            UITableLayout = {
                SortOrder = Enum.SortOrder.LayoutOrder,
            },
            UIPageLayout = {
                SortOrder = Enum.SortOrder.LayoutOrder,
            },
            VideoFrame = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
            },
            ViewportFrame = {
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderColor3 = Color3.new(0, 0, 0),
                BorderSizePixel = 0,
            },
        }
    end
    function __DARKLUA_BUNDLE_MODULES.j()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local defaults = __DARKLUA_BUNDLE_MODULES.load('i')
        local apply = __DARKLUA_BUNDLE_MODULES.load('g')
        local ctor_cache = {}

        setmetatable(ctor_cache, {
            __index = function(self, class)
                local ok, instance = pcall(Instance.new, class)

                if not ok then
                    throw(string.format('invalid class name, could not create instance of class %s', tostring(class)))
                end

                local default = defaults[class]

                if default then
                    for i, v in next, default do
                        (instance)[i] = v
                    end
                end

                local function ctor(properties)
                    return apply(instance:Clone(), properties)
                end

                self[class] = ctor

                return ctor
            end,
        })

        local function create_instance(class)
            return ctor_cache[class]
        end
        local function clone_instance(instance)
            return function(properties)
                local clone = instance:Clone()

                if not clone then
                    throw'attempt to clone a non-archivable instance'
                end

                return apply(clone, properties)
            end
        end
        local function create(class_or_instance)
            if type(class_or_instance) == 'string' then
                return create_instance(class_or_instance)
            elseif typeof(class_or_instance) == 'Instance' then
                return clone_instance(class_or_instance)
            else
                throw('bad argument #1, expected string or instance, got ' .. typeof(class_or_instance))

                return nil
            end
        end

        return (create)
    end
    function __DARKLUA_BUNDLE_MODULES.k()
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_source_node = graph.create_source_node
        local push_child_to_scope = graph.push_child_to_scope
        local update_descendants = graph.update_descendants

        local function source(initial_value)
            local node = create_source_node(initial_value)

            return function(...)
                if select('#', ...) == 0 then
                    push_child_to_scope(node)

                    return node.cache
                end

                local v = (...)

                if node.cache == v and (type(v) ~= 'table' or table.isfrozen(v)) then
                    return v
                end

                node.cache = v

                update_descendants(node)

                return v
            end
        end

        return source
    end
    function __DARKLUA_BUNDLE_MODULES.l()
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local assert_stable_scope = graph.assert_stable_scope
        local evaluate_node = graph.evaluate_node

        local function effect(callback, initial_value)
            local node = create_node(assert_stable_scope(), callback, initial_value)

            evaluate_node(node)
        end

        return effect
    end
    function __DARKLUA_BUNDLE_MODULES.m()
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local push_child_to_scope = graph.push_child_to_scope
        local assert_stable_scope = graph.assert_stable_scope
        local evaluate_node = graph.evaluate_node

        local function derive(source)
            local node = create_node(assert_stable_scope(), source, false)

            evaluate_node(node)

            return function()
                push_child_to_scope(node)

                return node.cache
            end
        end

        return derive
    end
    function __DARKLUA_BUNDLE_MODULES.n()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local get_scope = graph.get_scope
        local push_cleanup = graph.push_cleanup

        local function helper(obj)
            return typeof(obj) == 'RBXScriptConnection' and function()
                obj:Disconnect()
            end or (obj.Disconnect and function()
                obj:Disconnect()
            end or (obj.Destroy and function()
                obj:Destroy()
            end or (obj.disconnect and function()
                obj:disconnect()
            end or (obj.destroy and function()
                obj:destroy()
            end or (typeof(obj) == 'Instance' and function()
                obj:Destroy()
            end or throw('cannot cleanup given object'))))))
        end
        local function cleanup(value)
            local scope = get_scope()

            if not scope then
                throw'cannot cleanup outside a stable or reactive scope'
            end

            assert(scope)

            if type(value) == 'function' then
                push_cleanup(scope, value)
            else
                push_cleanup(scope, helper(value))
            end
        end

        return cleanup
    end
    function __DARKLUA_BUNDLE_MODULES.o()
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local get_scope = graph.get_scope

        local function untrack(source)
            local scope = get_scope()

            if scope then
                local effect = scope.effect

                scope.effect = false

                local ok, result = pcall(source)

                scope.effect = effect

                if not ok then
                    error(result, 0)
                end

                return result
            else
                return source()
            end
        end

        return untrack
    end
    function __DARKLUA_BUNDLE_MODULES.p()
        local function read(value)
            return (type(value) == 'function' and {
                (value()),
            } or {value})[1]
        end

        return read
    end
    function __DARKLUA_BUNDLE_MODULES.q()
        local flags = __DARKLUA_BUNDLE_MODULES.load('b')
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')

        local function batch(setter)
            local already_batching = flags.batch
            local from

            if not already_batching then
                flags.batch = true
                from = graph.get_update_queue_length()
            end

            local ok, err = pcall(setter)

            if not already_batching then
                flags.batch = false

                graph.flush_update_queue(from)
            end
            if not ok then
                throw(string.format('error occured while batching updates: %s', tostring(err)))
            end
        end

        return batch
    end
    function __DARKLUA_BUNDLE_MODULES.r()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local get_scope = graph.get_scope
        local push_scope = graph.push_scope
        local pop_scope = graph.pop_scope
        local set_context = graph.set_context
        local nil_symbol = newproxy()
        local count = 0

        local function context(...)
            count = count + 1

            local id = count
            local has_default = select('#', ...) > 0
            local default_value = ...

            return function(...)
                local scope = get_scope()

                if select('#', ...) == 0 then
                    while scope do
                        local __DARKLUA_CONTINUE_19 = false

                        repeat
                            local ctx = scope.context

                            if not ctx then
                                scope = scope.owner
                                __DARKLUA_CONTINUE_19 = true

                                break
                            end

                            local value = (ctx)[id]

                            if value == nil then
                                scope = scope.owner
                                __DARKLUA_CONTINUE_19 = true

                                break
                            end

                            return ((value ~= nil_symbol and {value} or {nil})[1])
                        until true

                        if not __DARKLUA_CONTINUE_19 then
                            break
                        end
                    end

                    if has_default ~= nil then
                        return default_value
                    else
                        throw(
[[attempt to get context when no context is set and no default context is set]])
                    end
                else
                    if not scope then
                        return throw('attempt to set context outside of a vide scope')
                    end

                    local value, component = ...
                    local new_scope = create_node(scope, false, false)

                    set_context(new_scope, id, (value == nil and {nil_symbol} or {value})[1])
                    push_scope(new_scope)

                    local function efn(err)
                        return debug.traceback(err, 3)
                    end

                    local ok, result = xpcall(component, efn)

                    pop_scope()

                    if not ok then
                        throw(string.format('error while running context:\n\n%s', tostring(result)))
                    end

                    return result
                end

                return nil
            end
        end

        return context
    end
    function __DARKLUA_BUNDLE_MODULES.s()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local evaluate_node = graph.evaluate_node
        local push_child_to_scope = graph.push_child_to_scope
        local destroy = graph.destroy
        local assert_stable_scope = graph.assert_stable_scope
        local push_scope = graph.push_scope
        local pop_scope = graph.pop_scope

        local function switch(source)
            local owner = assert_stable_scope()

            return function(map)
                local last_scope
                local last_component

                local function update(cached)
                    local component = map[source()]

                    if component == last_component then
                        return cached
                    end

                    last_component = component

                    if last_scope then
                        destroy(last_scope)

                        last_scope = nil
                    end
                    if component == nil then
                        return nil
                    end
                    if type(component) ~= 'function' then
                        throw'map must map a value to a function'
                    end

                    local new_scope = create_node(owner, false, false)

                    last_scope = new_scope

                    push_scope(new_scope)

                    local ok, result = pcall(component)

                    pop_scope()

                    if not ok then
                        error(result, 0)
                    end

                    return result
                end

                local node = create_node(owner, update, nil)

                evaluate_node(node)

                return function()
                    push_child_to_scope(node)

                    return node.cache
                end
            end
        end

        return switch
    end
    function __DARKLUA_BUNDLE_MODULES.t()
        local switch = __DARKLUA_BUNDLE_MODULES.load('s')

        local function show(source, component, fallback)
            local function truthy()
                return not not source()
            end

            return switch(truthy){
                [true] = component,
                [false] = fallback,
            }
        end

        return show
    end
    function __DARKLUA_BUNDLE_MODULES.u()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local flags = __DARKLUA_BUNDLE_MODULES.load('b')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local create_source_node = graph.create_source_node
        local push_child_to_scope = graph.push_child_to_scope
        local update_descendants = graph.update_descendants
        local assert_stable_scope = graph.assert_stable_scope
        local push_scope = graph.push_scope
        local pop_scope = graph.pop_scope
        local evaluate_node = graph.evaluate_node
        local destroy = graph.destroy

        local function check_primitives(t)
            if not flags.strict then
                return
            end

            for _, v in next, t do
                local __DARKLUA_CONTINUE_20 = false

                repeat
                    if type(v) == 'table' or type(v) == 'userdata' or type(v) == 'function' then
                        __DARKLUA_CONTINUE_20 = true

                        break
                    end

                    throw('table source map cannot return primitives')

                    __DARKLUA_CONTINUE_20 = true
                until true

                if not __DARKLUA_CONTINUE_20 then
                    break
                end
            end
        end
        local function indexes(input, transform)
            local owner = assert_stable_scope()
            local subowner = create_node(owner, false, false)
            local input_cache = {}
            local output_cache = {}
            local input_nodes = {}
            local remove_queue = {}
            local scopes = {}

            local function update_children(data)
                for i in next, input_cache do
                    if data[i] == nil then
                        table.insert(remove_queue, i)
                    end
                end
                for _, i in next, remove_queue do
                    destroy(scopes[i])

                    input_cache[i] = nil
                    output_cache[i] = nil
                    input_nodes[i] = nil
                    scopes[i] = nil
                end

                table.clear(remove_queue)
                push_scope(subowner)

                for i, v in next, data do
                    local cv = input_cache[i]

                    if cv ~= v then
                        if cv == nil then
                            local scope = create_node(subowner, false, false)

                            scopes[i] = scope

                            local node = create_source_node(v)

                            push_scope(scope)

                            local ok, result = pcall(transform, function()
                                push_child_to_scope(node)

                                return node.cache
                            end, i)

                            pop_scope()

                            if not ok then
                                pop_scope()
                                error(result, 0)
                            end

                            input_nodes[i] = node
                            output_cache[i] = result
                        else
                            input_nodes[i].cache = v

                            update_descendants(input_nodes[i])
                        end

                        input_cache[i] = v
                    end
                end

                pop_scope()

                local output_array = table.create(#scopes)

                for _, v in next, output_cache do
                    table.insert(output_array, v)
                end

                check_primitives(output_array)

                return output_array
            end

            local node = create_node(owner, function()
                return update_children(input())
            end, false)

            evaluate_node(node)

            return function()
                push_child_to_scope(node)

                return node.cache
            end
        end
        local function values(input, transform)
            local owner = assert_stable_scope()
            local subowner = create_node(owner, false, false)
            local cur_input_cache_up = {}
            local new_input_cache_up = {}
            local output_cache = {}
            local input_nodes = {}
            local scopes = {}

            local function update_children(data)
                local cur_input_cache, new_input_cache = cur_input_cache_up, new_input_cache_up

                if flags.strict then
                    local cache = {}

                    for _, v in next, data do
                        if cache[v] ~= nil then
                            throw'duplicate table value detected'
                        end

                        cache[v] = true
                    end
                end

                push_scope(subowner)

                for i, v in next, data do
                    new_input_cache[v] = i

                    local cv = cur_input_cache[v]

                    if cv == nil then
                        local scope = create_node(subowner, false, false)

                        scopes[v] = scope

                        local node = create_source_node(i)

                        push_scope(scope)

                        local ok, result = pcall(transform, v, function()
                            push_child_to_scope(node)

                            return node.cache
                        end)

                        pop_scope()

                        if not ok then
                            pop_scope()
                            error(result, 0)
                        end

                        input_nodes[v] = node
                        output_cache[v] = result
                    else
                        if cv ~= i then
                            input_nodes[v].cache = i

                            update_descendants(input_nodes[v])
                        end

                        cur_input_cache[v] = nil
                    end
                end

                pop_scope()

                for v in next, cur_input_cache do
                    destroy(scopes[v])

                    output_cache[v] = nil
                    input_nodes[v] = nil
                    scopes[v] = nil
                end

                table.clear(cur_input_cache)

                cur_input_cache_up, new_input_cache_up = new_input_cache, cur_input_cache

                local output_array = table.create(#scopes)

                for _, v in next, output_cache do
                    table.insert(output_array, v)
                end

                check_primitives(output_array)

                return output_array
            end

            local node = create_node(owner, function()
                return update_children(input())
            end, false)

            evaluate_node(node)

            return function()
                push_child_to_scope(node)

                return node.cache
            end
        end

        return function()
            return indexes, values
        end
    end
    function __DARKLUA_BUNDLE_MODULES.v()
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local graph = __DARKLUA_BUNDLE_MODULES.load('c')
        local create_node = graph.create_node
        local create_source_node = graph.create_source_node
        local assert_stable_scope = graph.assert_stable_scope
        local evaluate_node = graph.evaluate_node
        local update_descendants = graph.update_descendants
        local push_child_to_scope = graph.push_child_to_scope
        local UPDATE_RATE = 120
        local TOLERANCE = 0.0001

        local function Vec3(x, y, z)
            return Vector3.new(x, y, z)
        end

        local ZERO = Vec3(0, 0, 0)
        local type_to_vec6 = {
            number = function(v)
                return Vec3(v, 0, 0), ZERO
            end,
            CFrame = function(v)
                return v.Position, Vec3(v:ToEulerAnglesXYZ())
            end,
            Color3 = function(v)
                return Vec3(v.R, v.G, v.B), ZERO
            end,
            UDim = function(v)
                return Vec3(v.Scale, v.Offset, 0), ZERO
            end,
            UDim2 = function(v)
                return Vec3(v.X.Scale, v.X.Offset, v.Y.Scale), Vec3(v.Y.Offset, 0, 0)
            end,
            Vector2 = function(v)
                return Vec3(v.X, v.Y, 0), ZERO
            end,
            Vector3 = function(v)
                return v, ZERO
            end,
            Rect = function(v)
                return Vec3(v.Min.X, v.Min.Y, v.Max.X), Vec3(v.Max.Y, 0, 0)
            end,
        }
        local vec6_to_type = {
            number = function(a, b)
                return a.X
            end,
            CFrame = function(a, b)
                return CFrame.new(a) * CFrame.fromEulerAnglesXYZ(b.X, b.Y, b.Z)
            end,
            Color3 = function(v)
                return Color3.new(math.clamp(v.X, 0, 1), math.clamp(v.Y, 0, 1), math.clamp(v.Z, 0, 1))
            end,
            UDim = function(v)
                return UDim.new(v.X, math.round(v.Y))
            end,
            UDim2 = function(a, b)
                return UDim2.new(a.X, math.round(a.Y), a.Z, math.round(b.X))
            end,
            Vector2 = function(v)
                return Vector2.new(v.X, v.Y)
            end,
            Vector3 = function(v)
                return v
            end,
            Rect = function(a, b)
                return Rect.new(a.X, a.Y, a.Z, b.X)
            end,
        }
        local invalid_type = {
            __index = function(_, t)
                throw(string.format('cannot spring type %s', tostring(t)))
            end,
        }

        setmetatable(type_to_vec6, invalid_type)
        setmetatable(vec6_to_type, invalid_type)

        local springs = {}

        setmetatable(springs, {
            __mode = 'v',
        })

        local function spring(source, period, damping_ratio)
            local owner = assert_stable_scope()
            local w_n = 2 * math.pi / (period or 1)
            local z = damping_ratio or 1
            local k = w_n ^ 2
            local c_c = 2 * w_n
            local c = z * c_c

            if c > UPDATE_RATE * 2 then
                throw(
[[spring damping too high, consider reducing damping or increasing period]])
            end

            local data = {
                k = k,
                c = c,
                x0_123 = ZERO,
                x1_123 = ZERO,
                v_123 = ZERO,
                x0_456 = ZERO,
                x1_456 = ZERO,
                v_456 = ZERO,
                source_value = false,
            }
            local output = create_source_node(false)

            local function updater_effect()
                local value = source()

                data.x1_123, data.x1_456 = type_to_vec6[typeof(value)](value)
                data.source_value = value
                springs[data] = output

                return value
            end

            local updater = create_node(owner, updater_effect, false)

            evaluate_node(updater)

            data.x0_123, data.x0_456 = data.x1_123, data.x1_456
            output.cache = data.source_value

            return function(...)
                if select('#', ...) == 0 then
                    push_child_to_scope(output)

                    return output.cache
                end

                local v = (...)

                data.x0_123, data.x0_456 = type_to_vec6[typeof(v)](v)
                data.v_123 = ZERO
                data.v_456 = ZERO
                springs[data] = output
                output.cache = v

                return v
            end
        end
        local function step_springs(dt)
            for data in next, springs do
                local k, c, x0_123, x1_123, u_123, x0_456, x1_456, u_456 = data.k, data.c, data.x0_123, data.x1_123, data.v_123, data.x0_456, data.x1_456, data.v_456
                local dx_123 = x0_123 - x1_123
                local dx_456 = x0_456 - x1_456
                local fs_123 = dx_123 * -k
                local fs_456 = dx_456 * -k
                local ff_123 = u_123 * -c
                local ff_456 = u_456 * -c
                local dv_123 = (fs_123 + ff_123) * dt
                local dv_456 = (fs_456 + ff_456) * dt
                local v_123 = u_123 + dv_123
                local v_456 = u_456 + dv_456
                local x_123 = x0_123 + v_123 * dt
                local x_456 = x0_456 + v_456 * dt

                data.x0_123, data.x0_456 = x_123, x_456
                data.v_123, data.v_456 = v_123, v_456
            end
        end

        local remove_queue = {}

        local function update_spring_sources()
            for data, output in next, springs do
                local x0_123, x1_123, v_123, x0_456, x1_456, v_456 = data.x0_123, data.x1_123, data.v_123, data.x0_456, data.x1_456, data.v_456
                local dx_123, dx_456 = x0_123 - x1_123, x0_456 - x1_456

                if (v_123 + v_456 + dx_123 + dx_456).Magnitude < TOLERANCE then
                    table.insert(remove_queue, data)

                    output.cache = data.source_value
                else
                    output.cache = vec6_to_type[typeof(data.source_value)](x0_123, x0_456)
                end

                update_descendants(output)
            end
            for _, data in next, remove_queue do
                springs[data] = nil
            end

            table.clear(remove_queue)
        end

        return function()
            local time_elapsed = 0

            return spring, function(dt)
                time_elapsed = time_elapsed + dt

                while time_elapsed > 1 / UPDATE_RATE do
                    time_elapsed = time_elapsed - 1 / UPDATE_RATE

                    step_springs(1 / UPDATE_RATE)
                end

                update_spring_sources()
            end
        end
    end
    function __DARKLUA_BUNDLE_MODULES.w()
        local action = __DARKLUA_BUNDLE_MODULES.load('f')()
        local cleanup = __DARKLUA_BUNDLE_MODULES.load('n')

        local function changed(property, callback)
            return action(function(instance)
                local con = instance:GetPropertyChangedSignal(property):Connect(function()
                    callback((instance)[property])
                end)

                cleanup(function()
                    con:Disconnect()
                end)
                callback((instance)[property])
            end)
        end

        return changed
    end
    function __DARKLUA_BUNDLE_MODULES.x()
        local version = {
            major = 0,
            minor = 3,
            patch = 1,
        }
        local root = __DARKLUA_BUNDLE_MODULES.load('d')
        local mount = __DARKLUA_BUNDLE_MODULES.load('h')
        local create = __DARKLUA_BUNDLE_MODULES.load('j')
        local apply = __DARKLUA_BUNDLE_MODULES.load('g')
        local source = __DARKLUA_BUNDLE_MODULES.load('k')
        local effect = __DARKLUA_BUNDLE_MODULES.load('l')
        local derive = __DARKLUA_BUNDLE_MODULES.load('m')
        local cleanup = __DARKLUA_BUNDLE_MODULES.load('n')
        local untrack = __DARKLUA_BUNDLE_MODULES.load('o')
        local read = __DARKLUA_BUNDLE_MODULES.load('p')
        local batch = __DARKLUA_BUNDLE_MODULES.load('q')
        local context = __DARKLUA_BUNDLE_MODULES.load('r')
        local switch = __DARKLUA_BUNDLE_MODULES.load('s')
        local show = __DARKLUA_BUNDLE_MODULES.load('t')
        local indexes, values = __DARKLUA_BUNDLE_MODULES.load('u')()
        local spring, update_springs = __DARKLUA_BUNDLE_MODULES.load('v')()
        local action = __DARKLUA_BUNDLE_MODULES.load('f')()
        local changed = __DARKLUA_BUNDLE_MODULES.load('w')
        local throw = __DARKLUA_BUNDLE_MODULES.load('a')
        local flags = __DARKLUA_BUNDLE_MODULES.load('b')

        local function step(dt)
            if game then
                debug.profilebegin('VIDE STEP')
                debug.profilebegin('VIDE SPRING')
            end

            update_springs(dt)

            if game then
                debug.profileend()
                debug.profileend()
            end
        end

        local stepped = game and game:GetService('RunService').Heartbeat:Connect(function(dt)
            task.defer(step, dt)
        end)
        local vide = {
            version = version,
            root = root,
            mount = mount,
            create = create,
            source = source,
            effect = effect,
            derive = derive,
            switch = switch,
            show = show,
            indexes = indexes,
            values = values,
            cleanup = cleanup,
            untrack = untrack,
            read = read,
            batch = batch,
            context = context,
            spring = spring,
            action = action,
            changed = changed,
            strict = (nil),
            apply = function(instance)
                return function(props)
                    apply(instance, props)
                    return instance
                end
            end,
            step = function(dt)
                if stepped then
                    stepped:Disconnect()
                    stepped = nil
                end
                step(dt)
            end,
        }

        setmetatable(vide, {
            __index = function(_, index)
                if index == 'strict' then
                    return flags.strict
                else
                    throw(string.format('%s is not a valid member of vide', tostring(tostring(index))))
                end
            end,
            __newindex = function(_, index, value)
                if index == 'strict' then
                    flags.strict = value
                else
                    throw(string.format('%s is not a valid member of vide', tostring(tostring(index))))
                end
            end,
        })

        return vide
    end
    function __DARKLUA_BUNDLE_MODULES.y()
        local function parseTypeString(typeString)
            local types = {}
            local isOptional = false

            if string.match(typeString, '%?%s*$') then
                isOptional = true
                typeString = string.gsub(typeString, '%?%s*$', '')
            end

            for typeStr in string.gmatch(typeString, '([^|]+)') do
                local trimmed = string.match(typeStr, '^%s*(.-)%s*$')
                if string.match(trimmed, '%?%s*$') then
                    isOptional = true
                    trimmed = string.gsub(trimmed, '%?%s*$', '')
                end
                table.insert(types, trimmed)
            end

            if isOptional then
                table.insert(types, 'nil')
            end

            return types
        end
        local function check(data, schema)
            if type(data) ~= 'table' then
                error('First parameter must be a table, got ' .. type(data), 2)
            end
            if type(schema) ~= 'table' then
                error('Second parameter must be a table, got ' .. type(schema), 2)
            end

            for key, expectedType in pairs(schema) do
                if type(expectedType) ~= 'string' then
                    error("Schema value for key '" .. tostring(key) .. "' must be a string, got " .. type(expectedType), 2)
                end

                local value = data[key]
                local actualType = type(value)
                local expectedTypes = parseTypeString(expectedType)
                local typeMatches = false

                for _, expType in ipairs(expectedTypes) do
                    if actualType == expType then
                        typeMatches = true
                        break
                    end
                end

                if not typeMatches then
                    error("Type mismatch for key '" .. tostring(key) .. "': expected " .. expectedType .. ', got ' .. actualType, 2)
                end
            end
        end

        return check
    end
    function __DARKLUA_BUNDLE_MODULES.z()
        local check = __DARKLUA_BUNDLE_MODULES.load('y')
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local create = vide.create

        return function(props)
            check(props, { size = 'number?' })
            local size = props.size or 2
            return create'Folder'{
                Name = 'Shadow',
                create'ImageLabel'{
                    Name = 'ambientShadow',
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    BackgroundTransparency = 1,
                    Image = 'rbxassetid://1316045217',
                    ImageColor3 = Color3.new(),
                    ImageTransparency = 0.88,
                    Position = UDim2.fromScale(0.5, 0.5),
                    ScaleType = Enum.ScaleType.Slice,
                    Size = UDim2.new(1, size, 1, size),
                    SliceCenter = Rect.new(10, 10, 118, 118),
                    ZIndex = 0,
                },
                create'ImageLabel'{
                    Name = 'penumbraShadow',
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    BackgroundTransparency = 1,
                    Image = 'rbxassetid://1316045217',
                    ImageColor3 = Color3.new(),
                    ImageTransparency = 0.88,
                    Position = UDim2.fromScale(0.5, 0.5),
                    ScaleType = Enum.ScaleType.Slice,
                    Size = UDim2.new(1, size, 1, size),
                    SliceCenter = Rect.new(10, 10, 118, 118),
                    ZIndex = 0,
                },
                create'ImageLabel'{
                    Name = 'umbraShadow',
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    BackgroundTransparency = 1,
                    Image = 'rbxassetid://1316045217',
                    ImageColor3 = Color3.new(),
                    ImageTransparency = 0.84,
                    Position = UDim2.fromScale(0.5, 0.5),
                    ScaleType = Enum.ScaleType.Slice,
                    Size = UDim2.new(1, size, 1, size),
                    SliceCenter = Rect.new(10, 10, 118, 118),
                    ZIndex = 0,
                },
            }
        end
    end
    function __DARKLUA_BUNDLE_MODULES.A()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local derive = vide.derive
        local create = vide.create
        local verticalSize = UDim2.new(0, 1, 1, 0)
        local horizontalSize = UDim2.new(1, 0, 0, 1)

        return function(props)
            local mode = props.mode
            return create'Frame'{
                Name = 'Separator',
                BackgroundColor3 = Color3.fromRGB(45, 45, 45),
                BorderColor3 = Color3.new(),
                BorderSizePixel = 0,
                LayoutOrder = 0,
                Size = derive(function()
                    return (mode() == 'vertical' and {verticalSize} or {horizontalSize})[1]
                end),
                create'UIFlexItem'{ Name = 'UIFlexItem' },
            }
        end
    end
    function __DARKLUA_BUNDLE_MODULES.B()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local create = vide.create
        local UserInputService = game:GetService('UserInputService')
        local resizeHandleSize = 12
        local resizeHandleConfigurationMap = {
            bottom = {
                position = UDim2.new(0, 0, 1, 0),
                size = UDim2.new(1, 0, 0, resizeHandleSize),
                anchorPoint = Vector2.new(0, 1),
            },
            right = {
                position = UDim2.new(1, 0, 0, 0),
                size = UDim2.new(0, resizeHandleSize, 1, 0),
                anchorPoint = Vector2.new(1, 0),
            },
            corner = {
                position = UDim2.new(1, 0, 1, 0),
                size = UDim2.new(0, resizeHandleSize, 0, resizeHandleSize),
                anchorPoint = Vector2.new(1, 1),
            },
        }
        local MouseMovement = Enum.UserInputType.MouseMovement

        return function(props)
            local handleMode = props.handleMode
            local resizeMode = props.resizeMode
            local resizeStart = props.resizeStart
            local startSize = props.startSize
            local isResizing = props.isResizing
            local frame
            local startMousePosition

            UserInputService.InputChanged:Connect(function(input)
                if input.UserInputType ~= MouseMovement then return end
                if input.UserInputState == Enum.UserInputState.Change then
                    if isResizing() then
                        local position = input.Position
                        if handleMode == 'corner' then
                            frame.Size = UDim2.fromOffset(startSize().X + position.X - startMousePosition.X, startSize().Y + position.Y - startMousePosition.Y)
                        elseif handleMode == 'right' then
                            frame.Size = UDim2.fromOffset(startSize().X + position.X - startMousePosition.X, 0)
                        elseif handleMode == 'bottom' then
                            frame.Size = UDim2.fromOffset(0, startSize().Y + position.Y - startMousePosition.Y)
                        end
                    end
                elseif input.UserInputState == Enum.UserInputState.End then
                    isResizing(false)
                end
            end)

            local configuration = resizeHandleConfigurationMap[handleMode]

            return create'Frame'{
                BackgroundTransparency = 1,
                Position = configuration.position,
                Size = configuration.size,
                AnchorPoint = configuration.anchorPoint,
                ZIndex = 10,
                vide.changed('Parent', function(parent)
                    frame = parent
                end),
                create'UIFlexItem'{},
                InputBegan = function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 then
                        isResizing(true)
                        startSize(frame.AbsoluteSize)
                        resizeMode(handleMode)
                        resizeStart(input.Position)
                        startMousePosition = input.Position
                    end
                end,
                InputEnded = function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 then
                        isResizing(false)
                    end
                end,
                MouseEnter = function()
                    resizeMode(handleMode)
                end,
            }
        end
    end
    function __DARKLUA_BUNDLE_MODULES.C()
        local UserInputService = game:GetService('UserInputService')
        local TweenService = game:GetService('TweenService')
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local cleanup = vide.cleanup
        local effect = vide.effect
        local create = vide.create
        local source = vide.source
        local Shadow = __DARKLUA_BUNDLE_MODULES.load('z')
        local Separator = __DARKLUA_BUNDLE_MODULES.load('A')
        local ResizeHandle = __DARKLUA_BUNDLE_MODULES.load('B')
        local viewportSize = workspace.CurrentCamera.ViewportSize
        local viewportSizeX = viewportSize.X
        local viewportSizeY = viewportSize.Y - 58

        local function ClampPositionToScreen(position, size)
            local positionX = position.X.Offset
            local positionY = position.Y.Offset
            local clampedX = math.clamp(positionX, 0, viewportSizeX - size.X)
            local clampedY = math.clamp(positionY, 0, viewportSizeY - size.Y)
            return UDim2.fromOffset(clampedX, clampedY)
        end

        local dragPreviewFrameFadeStyle = TweenInfo.new(0.3)

        local function UpdateFrameDragPosition(frame, size, dragPreviewFrame, dragStart, startPos, input)
            local deltaX = input.Position.X - dragStart.X
            local deltaY = input.Position.Y - dragStart.Y
            local positionX = startPos.X.Offset + deltaX
            local positionY = startPos.Y.Offset + deltaY
            local position = ClampPositionToScreen(UDim2.fromOffset(positionX, positionY), frame.AbsoluteSize)
            local distance = (Vector2.new(position.X, position.Y) - Vector2.new(positionX, positionY)).Magnitude
            frame:TweenPosition(position, nil, Enum.EasingStyle.Back, (distance / distance) / 3, true)
            TweenService:Create(dragPreviewFrame, dragPreviewFrameFadeStyle, {Transparency = 0.9}):Play()
            dragPreviewFrame.Position = position
        end

        local MouseMovement = Enum.UserInputType.MouseMovement

        local function Window(props)
            local size = source(props.size or UDim2.fromOffset(300, 250))
            local isOpenedSources = props.isOpenedSources
            local showSidebar = #props.categories > 1

            for i, v in props.categories do
                effect(function()
                    local state = isOpenedSources[i]()
                    if not state then return end
                    for e, k in isOpenedSources do
                        local __DARKLUA_CONTINUE_37 = false
                        repeat
                            if e == i then __DARKLUA_CONTINUE_37 = true break end
                            k(false)
                            __DARKLUA_CONTINUE_37 = true
                        until true
                        if not __DARKLUA_CONTINUE_37 then break end
                    end
                end)
            end

            local dragging = source(false)
            local isResizing = source(false)
            local dragStart, startPos

            cleanup(UserInputService.InputEnded:Connect(function(input)
                if dragging() and input.UserInputType == Enum.UserInputType.MouseButton1 then
                    dragging(false)
                end
            end))

            local Window
            local DragPreviewFrame

            cleanup(UserInputService.InputChanged:Connect(function(input)
                if dragging() and input.UserInputType == MouseMovement then
                    UpdateFrameDragPosition(Window, size, DragPreviewFrame, dragStart, startPos, input)
                end
            end))

            DragPreviewFrame = create'Frame'{
                Name = 'Frame1',
                BackgroundColor3 = Color3.fromRGB(15, 15, 15),
                BackgroundTransparency = 0.5,
                ClipsDescendants = true,
                Position = UDim2.fromOffset(20, 20),
                Size = size,
                Visible = true,
                ZIndex = -1,
                create'UICorner'{ Name = 'UICorner', CornerRadius = UDim.new(0, 6) },
                Name = 'Frame1',
                BackgroundColor3 = Color3.fromRGB(18, 18, 18),
                ClipsDescendants = false,
                Position = UDim2.fromOffset(20, 20),
                Size = size,
                InputBegan = function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 then
                        if not isResizing() then
                            startPos = Window.Position
                            dragStart = input.Position
                            dragging(true)
                        end
                    end
                end,
                create'UIGradient'{
                    Color = ColorSequence.new{
                        ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 28, 28)),
                        ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 8, 8)),
                    },
                    Rotation = 135,
                },
                ResizeHandle({
                    handleMode = 'corner',
                    resizeMode = source(),
                    resizeStart = source(),
                    startSize = source(),
                    isResizing = isResizing,
                }),
                create'Frame'{
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 1, 0),
                    Name = 'Content',
                    props.containers,
                    create'UIListLayout'{
                        FillDirection = Enum.FillDirection.Horizontal,
                        HorizontalFlex = Enum.UIFlexAlignment.Fill,
                        SortOrder = Enum.SortOrder.LayoutOrder,
                        VerticalAlignment = Enum.VerticalAlignment.Top,
                    },
                    create'Frame'{
                        Name = 'Sidebar',
                        BackgroundColor3 = Color3.fromRGB(20, 20, 20),
                        BackgroundTransparency = 0,
                        Size = UDim2.new(0, showSidebar and 34 or 0, 1, 0),
                        Visible = showSidebar,
                        create'UIPadding'{
                            PaddingBottom = UDim.new(0, 4),
                            PaddingLeft = UDim.new(0, 4),
                            PaddingRight = UDim.new(0, 4),
                            PaddingTop = UDim.new(0, 4),
                        },
                        create'UIFlexItem'{},
                        create'Frame'{
                            Name = 'Categories',
                            BackgroundTransparency = 1,
                            Size = UDim2.fromScale(1, 1),
                            create'UIListLayout'{
                                HorizontalAlignment = Enum.HorizontalAlignment.Center,
                                Padding = UDim.new(0, 1),
                                SortOrder = Enum.SortOrder.LayoutOrder,
                            },
                            props.categories,
                        },
                        create'UIListLayout'{
                            SortOrder = Enum.SortOrder.LayoutOrder,
                            VerticalFlex = Enum.UIFlexAlignment.Fill,
                        },
                    },
                    (showSidebar and Separator({ mode = source('vertical') }) or nil),
                },
                Shadow({}),
                create'UISizeConstraint'{
                    MinSize = Vector2.new(280, 220),
                    MaxSize = Vector2.new(500, 420),
                },
            }

            return Window, DragPreviewFrame
        end

        return Window
    end
    function __DARKLUA_BUNDLE_MODULES.D()
        return {
            size = 24,
            image = 137475077473068,
            columns = 35,
            icons = {
                ['activity'] = Vector2.zero,
                ['user-02'] = Vector2.zero,
                ['check'] = Vector2.zero,
                ['check-circle'] = Vector2.zero,
                ['settings'] = Vector2.zero,
                ['home'] = Vector2.zero,
                ['search-lg'] = Vector2.zero,
                ['bell'] = Vector2.zero,
                ['trash'] = Vector2.zero,
                ['edit-01'] = Vector2.zero,
                ['plus'] = Vector2.zero,
                ['minus'] = Vector2.zero,
                ['x'] = Vector2.zero,
                ['arrow-up'] = Vector2.zero,
                ['arrow-down'] = Vector2.zero,
                ['arrow-left'] = Vector2.zero,
                ['arrow-right'] = Vector2.zero,
                ['menu'] = Vector2.zero,
                ['lock'] = Vector2.zero,
                ['unlock'] = Vector2.zero,
                ['eye'] = Vector2.zero,
                ['eye-off'] = Vector2.zero,
                ['heart'] = Vector2.zero,
                ['star'] = Vector2.zero,
                ['info-circle'] = Vector2.zero,
                ['alert-circle'] = Vector2.zero,
                ['alert-triangle'] = Vector2.zero,
                ['download'] = Vector2.zero,
                ['upload'] = Vector2.zero,
                ['share'] = Vector2.zero,
                ['copy'] = Vector2.zero,
                ['clipboard'] = Vector2.zero,
                ['file'] = Vector2.zero,
                ['folder'] = Vector2.zero,
                ['image'] = Vector2.zero,
                ['video-recorder'] = Vector2.zero,
                ['microphone'] = Vector2.zero,
                ['headphones'] = Vector2.zero,
                ['volume-max'] = Vector2.zero,
                ['volume-x'] = Vector2.zero,
                ['wifi-off'] = Vector2.zero,
                ['bluetooth-on'] = Vector2.zero,
                ['battery-full'] = Vector2.zero,
                ['battery-empty'] = Vector2.zero,
                ['globe'] = Vector2.zero,
                ['map'] = Vector2.zero,
                ['marker-pin'] = Vector2.zero,
                ['calendar'] = Vector2.zero,
                ['clock'] = Vector2.zero,
                ['mail'] = Vector2.zero,
                ['phone'] = Vector2.zero,
                ['camera'] = Vector2.zero,
                ['tag'] = Vector2.zero,
                ['bookmark'] = Vector2.zero,
                ['flag'] = Vector2.zero,
                ['tool'] = Vector2.zero,
                ['code'] = Vector2.zero,
                ['terminal'] = Vector2.zero,
                ['database'] = Vector2.zero,
                ['server'] = Vector2.zero,
                ['cpu-chip'] = Vector2.zero,
                ['monitor'] = Vector2.zero,
                ['laptop'] = Vector2.zero,
                ['tablet'] = Vector2.zero,
                ['mobile'] = Vector2.zero,
                ['keyboard'] = Vector2.zero,
                ['mouse'] = Vector2.zero,
                ['printer'] = Vector2.zero,
                ['gift'] = Vector2.zero,
                ['shopping-cart'] = Vector2.zero,
                ['credit-card'] = Vector2.zero,
                ['bank'] = Vector2.zero,
                ['coins'] = Vector2.zero,
                ['bar-chart'] = Vector2.zero,
                ['pie-chart'] = Vector2.zero,
                ['line-chart-up'] = Vector2.zero,
                ['trend-up'] = Vector2.zero,
                ['trend-down'] = Vector2.zero,
                ['filter-funnel'] = Vector2.zero,
                ['sort'] = Vector2.zero,
                ['grid'] = Vector2.zero,
                ['list'] = Vector2.zero,
                ['columns'] = Vector2.zero,
                ['rows'] = Vector2.zero,
                ['user'] = Vector2.zero,
                ['users'] = Vector2.zero,
                ['message-circle'] = Vector2.zero,
                ['message-square'] = Vector2.zero,
                ['send'] = Vector2.zero,
                ['inbox'] = Vector2.zero,
                ['notification-box'] = Vector2.zero,
                ['layers-two'] = Vector2.zero,
                ['layers-three'] = Vector2.zero,
                ['anchor'] = Vector2.zero,
                ['compass'] = Vector2.zero,
                ['telescope'] = Vector2.zero,
                ['rocket'] = Vector2.zero,
                ['beaker'] = Vector2.zero,
                ['atom'] = Vector2.zero,
                ['sun'] = Vector2.zero,
                ['moon'] = Vector2.zero,
                ['cloud'] = Vector2.zero,
                ['drop'] = Vector2.zero,
                ['snowflake'] = Vector2.zero,
                ['hurricane'] = Vector2.zero,
            },
        }
    end
    function __DARKLUA_BUNDLE_MODULES.E()
        local icons = {
            untitled = __DARKLUA_BUNDLE_MODULES.load('D'),
        }

        local function ProcessIconsMap(iconsList, iconsMap, image, iconSize, sizeOffset, columns)
            for iconIndex, iconName in iconsList do
                iconIndex = iconIndex - 1
                iconsMap[iconName] = {
                    image = image,
                    size = iconSize,
                    position = Vector2.new((iconIndex % columns) * sizeOffset, math.floor((iconIndex / columns)) * sizeOffset),
                }
            end
        end

        for _, pack in icons do
            pack.image = 'rbxassetid://' .. pack.image
            local sizeOffset = pack.size
            local iconsMap = pack.icons
            local iconsList = {}
            for i, v in iconsMap do table.insert(iconsList, i) end
            table.sort(iconsList)
            local columns = pack.columns
            if not columns then
                local totalIcons = 0
                for i, v in iconsMap do totalIcons = totalIcons + 1 end
                columns = math.ceil(math.sqrt(totalIcons))
            end
            local iconSize = Vector2.new(sizeOffset, sizeOffset)
            ProcessIconsMap(iconsList, iconsMap, pack.image, iconSize, sizeOffset, columns)
        end

        return icons
    end
    function __DARKLUA_BUNDLE_MODULES.F()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local create = vide.create
        local fontWeightMap = {
            ['semi-bold'] = Enum.FontWeight.SemiBold,
            ['bold'] = Enum.FontWeight.Bold,
        }

        return function(props)
            local weight = props.fontWeight
            return create'TextLabel'{
                Name = 'Label',
                BackgroundTransparency = 1,
                ClipsDescendants = true,
                FontFace = Font.new('rbxasset://fonts/families/Ubuntu.json', weight and fontWeightMap[weight] or Enum.FontWeight.Regular),
                AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.new(0, 0, 0, 20),
                Text = props.content,
                TextColor3 = props.color or Color3.fromRGB(195, 195, 195),
                TextSize = props.size or 10,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = props.layoutOrder or 0,
                create'UIPadding'{
                    PaddingLeft = UDim.new(0, props.paddingLeft or 0),
                    PaddingRight = UDim.new(0, props.paddingRight or 0),
                },
            }
        end
    end
    function __DARKLUA_BUNDLE_MODULES.G()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local derive = vide.derive
        local source = vide.source
        local create = vide.create
        local indexes = vide.indexes
        local icons = __DARKLUA_BUNDLE_MODULES.load('E')
        local Label = __DARKLUA_BUNDLE_MODULES.load('F')
        local Separator = __DARKLUA_BUNDLE_MODULES.load('A')

        local function Category(props)
            local icon = props.icon
            local isOpened = props.isOpened
            local sections = source(props.sections)
            local container = create'ScrollingFrame'{
                Name = 'Container',
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                ClipsDescendants = true,
                LayoutOrder = 2,
                ScrollBarThickness = 0,
                Selectable = false,
                Size = UDim2.fromScale(1, 1),
                Visible = isOpened,
                create'UIListLayout'{
                    Padding = UDim.new(0, 6),
                    Name = 'UIListLayout',
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    HorizontalFlex = Enum.UIFlexAlignment.Fill,
                    FillDirection = Enum.FillDirection.Horizontal,
                    Wraps = true,
                },
                create'UIPadding'{
                    Name = 'UIPadding',
                    PaddingLeft = UDim.new(0, 6),
                    PaddingTop = UDim.new(0, 4),
                    PaddingRight = UDim.new(0, 6),
                },
                indexes(sections, function(section, i)
                    local sectionFrame = create'Frame'{
                        Name = 'Section',
                        BackgroundTransparency = 1,
                        AutomaticSize = Enum.AutomaticSize.Y,
                        Size = UDim2.new(0, 200, 0, 0),
                        create'UIListLayout'{
                            Name = 'UIListLayout',
                            Padding = UDim.new(0, 0),
                            SortOrder = Enum.SortOrder.LayoutOrder,
                            HorizontalFlex = Enum.UIFlexAlignment.Fill,
                            FillDirection = Enum.FillDirection.Horizontal,
                            Wraps = true,
                        },
                        unpack(section().content),
                    }
                    return {sectionFrame}
                end),
            }
            local category = create'ImageButton'{
                Name = 'Category',
                BackgroundTransparency = 1,
                Size = UDim2.fromScale(1, 1),
                Activated = function()
                    isOpened(not isOpened())
                end,
                create'UICorner'{ Name = 'UICorner', CornerRadius = UDim.new(0, 6) },
                create'ImageLabel'{
                    Name = 'Icon',
                    Active = true,
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    BackgroundTransparency = 1,
                    Image = icon.image,
                    ImageRectOffset = icon.position,
                    ImageRectSize = icon.size,
                    ImageTransparency = derive(function()
                        return isOpened() and 0 or 0.5
                    end),
                    Position = UDim2.fromScale(0.5, 0.5),
                    Selectable = true,
                    Size = UDim2.fromOffset(15, 15),
                },
                create'UIAspectRatioConstraint'{ Name = 'UIAspectRatioConstraint' },
            }
            return category, container
        end

        return Category
    end
    function __DARKLUA_BUNDLE_MODULES.H()
        local RunService = game:GetService('RunService')
        local Lerp = {}

        function Lerp:TweenPartCFrame(part, goalCFrame, duration, onComplete)
            duration = math.max(duration or 1, 0.03)
            assert(part and part:IsA('BasePart'), 'Expected BasePart at argument #1')
            assert(goalCFrame and typeof(goalCFrame) == 'CFrame', 'Expected CFrame at argument #2')
            local startCFrame = part.CFrame
            local startTime = tick()
            local connection
            connection = RunService.PreRender:Connect(function()
                if not part or not part.Parent then
                    connection:Disconnect()
                    return
                end
                local alpha = math.min((tick() - startTime) / duration, 1)
                part.CFrame = startCFrame:lerp(goalCFrame, alpha)
                if alpha >= 1 then
                    connection:Disconnect()
                    part.CFrame = goalCFrame
                    if onComplete then onComplete() end
                end
            end)
            return connection
        end

        return Lerp
    end
    function __DARKLUA_BUNDLE_MODULES.I()
        local LerpTween = __DARKLUA_BUNDLE_MODULES.load('H')
        local player = game:GetService('Players').LocalPlayer
        local groundDirection = Vector3.new(0, -100, 0)

        local function RaycastAnimalGround()
            if not player.Character then return nil end
            local origin = player.Character:GetPivot().Position
            local result = workspace:Raycast(origin, groundDirection)
            return result
        end

        local Animal = {
            basicAttackCooldown = 0.6,
            specialAttackCooldown = 1.9,
        }
        local ReplicatedStorage = game:GetService('ReplicatedStorage')
        local AttackHandlerRemoteEvent = ReplicatedStorage.AttackHandlerRemoteEvent

        function Animal.BasicAttack(targetHumanoid)
            AttackHandlerRemoteEvent:FireServer(targetHumanoid)
            if not player.Character then return end
            player.Character:SetAttribute('LastBasicAttack', tick())
        end

        local SpecialAttackRemoteEvent_RegularAttack = ReplicatedStorage.SpecialAttackRemoteEvent_RegularAttack

        function Animal.SpecialAttack(targetHumanoid)
            SpecialAttackRemoteEvent_RegularAttack:FireServer(targetHumanoid)
            if not player.Character then return end
            player.Character:SetAttribute('LastSpecialAttack', tick())
        end
        function Animal.IsBasicAttackOnCooldown()
            if not player.Character then return false end
            local last = player.Character:GetAttribute('LastBasicAttack')
            return last and tick() - last < Animal.basicAttackCooldown
        end
        function Animal.IsSpecialAttackOnCooldown()
            if not player.Character then return false end
            local last = player.Character:GetAttribute('LastSpecialAttack')
            return last and tick() - last < Animal.specialAttackCooldown
        end
        function Animal.IsOnGrass()
            local result = RaycastAnimalGround()
            return result and result.Material == Enum.Material.Grass
        end
        function Animal.IsOnWater()
            local result = RaycastAnimalGround()
            return result and result.Material == Enum.Material.Water
        end

        local terrainCellSize = Vector3.new(4, 4, 4)

        function Animal.IsInsideTerrain()
            local character = player.Character
            if not character then return false end
            local root = character:FindFirstChild("HumanoidRootPart")
            if not root then return false end
            local position = root.Position
            if position.Magnitude == 0 then return false end
            local ok, result = pcall(function()
                local region = Region3.new(position, position + terrainCellSize):ExpandToGrid(4)
                local _, occupancies = workspace.Terrain:ReadVoxels(region, 4)
                return occupancies[1][1][1] > 0
            end)
            if not ok then return false end
            return result
        end

        local maxStudsPerSecond = 80
        local activeTweenConnection
        local activeTweenPart

        local function cancelActiveTween(zeroVelocity)
            if activeTweenConnection then
                activeTweenConnection:Disconnect()
                activeTweenConnection = nil
            end
            if zeroVelocity and activeTweenPart and activeTweenPart.Parent then
                activeTweenPart.AssemblyLinearVelocity = Vector3.zero
                activeTweenPart.AssemblyAngularVelocity = Vector3.zero
            end
            activeTweenPart = nil
            shared._animalTweening = false
        end

        function Animal.CancelTween(zeroVelocity)
            cancelActiveTween(zeroVelocity)
        end
        function Animal.IsTweening()
            return activeTweenConnection ~= nil
        end
        function Animal.TweenTo(cframe)
            local character = player.Character
            if not character then return end
            local root = character:FindFirstChild("HumanoidRootPart")
            if not root then return end
            local rootPosition = root.Position
            local duration = (cframe.Position - rootPosition).Magnitude / maxStudsPerSecond
            cancelActiveTween(true)
            local connection
            connection = LerpTween:TweenPartCFrame(root, cframe, duration, function()
                if activeTweenConnection == connection then
                    activeTweenConnection = nil
                    activeTweenPart = nil
                    shared._animalTweening = false
                end
            end)
            activeTweenConnection = connection
            activeTweenPart = root
            shared._animalTweening = true
            return duration
        end
        function Animal.TweenToAsync(cframe)
            local duration = Animal.TweenTo(cframe)
            if duration then task.wait(duration) end
        end

        return Animal
    end
    function __DARKLUA_BUNDLE_MODULES.J()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local create = vide.create

        return function(props)
            local icon = props.icon
            local size = props.size or 10
            return create'ImageLabel'{
                Name = 'Icon',
                AnchorPoint = Vector2.new(0.5, 0.5),
                BackgroundTransparency = 1,
                Image = icon.image,
                ImageRectOffset = icon.position,
                ImageRectSize = icon.size,
                Position = UDim2.fromScale(0.5, 0.5),
                ScaleType = Enum.ScaleType.Fit,
                Size = UDim2.fromOffset(size, size),
                ImageColor3 = props.color or Color3.new(1, 1, 1),
                create'UIFlexItem'{},
            }
        end
    end
    function __DARKLUA_BUNDLE_MODULES.K()
        local check = __DARKLUA_BUNDLE_MODULES.load('y')
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local create = vide.create
        local barBackground = Color3.fromRGB(55, 55, 55)

        local function CreateTrailBar(isFinalizer, size)
            return create'Frame'{
                Name = 'FrameHorizontal',
                AnchorPoint = Vector2.new(0, 0.5),
                BackgroundColor3 = barBackground,
                BorderSizePixel = 0,
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.new(0.5, 0, 0, 1),
            }, create'Frame'{
                Name = 'FrameVertical',
                AnchorPoint = Vector2.new(0.5, 0),
                BackgroundColor3 = barBackground,
                BorderSizePixel = 0,
                Position = UDim2.fromScale(0.5, 0),
                Size = UDim2.new(0, 1, isFinalizer and 0.5 or 1, 0),
            }, create'UISizeConstraint'{
                MinSize = Vector2.new(0, 0),
                MaxSize = Vector2.new(size, size),
            }
        end

        local function TreeChildTrail(props)
            check(props, { isFinalizer = 'boolean', size = 'number?' })
            local isFinalizer = props.isFinalizer
            local size = props.size or 20
            return create'Frame'{
                Size = UDim2.new(0, size, 0, size),
                BackgroundTransparency = 1,
                CreateTrailBar(isFinalizer, size),
            }
        end

        return TreeChildTrail
    end
    function __DARKLUA_BUNDLE_MODULES.L()
        local ControlManager = {
            states = {
                character = { controlled = false, priority = 0, owner = nil },
                camera    = { controlled = false, priority = 0, owner = nil },
            },
            timeouts = {},
            events = {},
        }

        function ControlManager:requestControl(owner, controlType, priority, timeout)
            local state = self.states[controlType]
            if not state then return false end
            if state.controlled and priority <= state.priority then return false end
            if state.controlled then self:releaseControl(controlType) end
            state.controlled = true
            state.priority = priority
            state.owner = owner
            if timeout then
                self.timeouts[controlType] = task.delay(timeout, function()
                    if state.owner == owner then self:releaseControl(controlType) end
                end)
            end
            self:emit('control_taken', { controlType = controlType, owner = owner, priority = priority })
            return true
        end
        function ControlManager:releaseControl(controlType, owner)
            local state = self.states[controlType]
            if not state or not state.controlled then return end
            if owner and state.owner ~= owner then return end
            local oldOwner = state.owner
            state.controlled = false
            state.priority = 0
            state.owner = nil
            if self.timeouts[controlType] then
                task.cancel(self.timeouts[controlType])
                self.timeouts[controlType] = nil
            end
            self:emit('control_released', { controlType = controlType, owner = oldOwner })
        end
        function ControlManager:hasControl(owner, controlType)
            local state = self.states[controlType]
            return state and state.controlled and state.owner == owner
        end
        function ControlManager:canTakeControl(controlType, priority)
            local state = self.states[controlType]
            return not state or not state.controlled or priority > state.priority
        end
        function ControlManager:emit(event, data)
            local listeners = self.events[event] or {}
            for _, callback in ipairs(listeners) do task.spawn(callback, data) end
        end
        function ControlManager:on(event, callback)
            if not self.events[event] then self.events[event] = {} end
            table.insert(self.events[event], callback)
        end

        return ControlManager
    end
    function __DARKLUA_BUNDLE_MODULES.M()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local cleanup = vide.cleanup
        local effect = vide.effect
        local source = vide.source
        local create = vide.create
        local Icon = __DARKLUA_BUNDLE_MODULES.load('J')
        local Label = __DARKLUA_BUNDLE_MODULES.load('F')
        local TreeChildTrail = __DARKLUA_BUNDLE_MODULES.load('K')
        local ControlManager = __DARKLUA_BUNDLE_MODULES.load('L')

        local function Checkbox(props)
            local isChecked = props.isChecked
            if not isChecked or type(isChecked) == 'boolean' then
                isChecked = source(isChecked or false)
            end

            cleanup(function()
                if isChecked() then
                    print(props.label, isChecked())
                    isChecked(false)
                end
            end)

            local isDisabled = props.isDisabled or source(false)
            local childs = props.childs and source(props.childs)
            local ownerId = tostring({})

            local function requestAllControls()
                if not props.controlPriority then return true end
                local acquired = {}
                for controlType, priority in pairs(props.controlPriority) do
                    if ControlManager:requestControl(ownerId, controlType, priority, props.controlTimeout) then
                        table.insert(acquired, controlType)
                    else
                        for _, acquiredType in ipairs(acquired) do
                            ControlManager:releaseControl(acquiredType, ownerId)
                        end
                        return false
                    end
                end
                return true
            end
            local function hasRequiredControl()
                if not props.controlPriority then return true end
                for controlType, priority in pairs(props.controlPriority) do
                    if not ControlManager:hasControl(ownerId, controlType) then return false end
                end
                return true
            end
            local function releaseAllControls()
                if not props.controlPriority then return end
                for controlType, _ in pairs(props.controlPriority) do
                    ControlManager:releaseControl(controlType, ownerId)
                end
            end

            local whenCheckedConnections = {}
            local function addWhenCheckedConnection(connection)
                table.insert(whenCheckedConnections, connection)
            end
            local function cleanupWhenChecked()
                for _, connection in ipairs(whenCheckedConnections) do
                    if connection.Connected then connection:Disconnect() end
                end
                whenCheckedConnections = {}
            end
            local function whileCheckedLoop()
                local WhileChecked = props.WhileChecked
                if not WhileChecked then return end
                while isChecked() do
                    local hasRequired = hasRequiredControl()
                    if hasRequired or requestAllControls() then
                        local returnValue = WhileChecked()
                        if returnValue == false then releaseAllControls() end
                    end
                    task.wait()
                end
            end
            local function onCheckedChanged(newState)
                if props.OnChanged then task.spawn(props.OnChanged, newState) end
                if newState then
                    if props.WhenChecked then task.spawn(props.WhenChecked, addWhenCheckedConnection) end
                    task.spawn(whileCheckedLoop)
                else
                    cleanupWhenChecked()
                    releaseAllControls()
                end
            end

            effect(function()
                onCheckedChanged(isChecked())
            end)

            local checkboxFrame = create'Frame'{
                Name = 'Checkbox',
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, 20),
                create'UIListLayout'{
                    FillDirection = Enum.FillDirection.Horizontal,
                    HorizontalFlex = Enum.UIFlexAlignment.Fill,
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    VerticalAlignment = Enum.VerticalAlignment.Center,
                },
                Label({ content = props.label }),
                create'ImageButton'{
                    Name = 'CheckButton',
                    BackgroundColor3 = Color3.fromRGB(30, 30, 30),
                    BackgroundTransparency = 0,
                    Size = UDim2.fromOffset(36, 16),
                    Activated = function()
                        if not isDisabled() then isChecked(not isChecked()) end
                    end,
                    create'UICorner'{ CornerRadius = UDim.new(1, 0) },
                    create'Frame'{
                        Name = 'Knob',
                        AnchorPoint = Vector2.new(0, 0.5),
                        Position = UDim2.new(0, 2, 0.5, 0),
                        Size = UDim2.fromOffset(12, 12),
                        BackgroundColor3 = Color3.fromRGB(90, 90, 90),
                        BorderSizePixel = 0,
                        create'UICorner'{ CornerRadius = UDim.new(1, 0) },
                    },
                    create'UIFlexItem'{},
                },
            }

            effect(function()
                local transparency = isDisabled() and 0.5 or 0
                checkboxFrame.CheckButton.Active = not isDisabled()
                checkboxFrame.CheckButton.BackgroundTransparency = transparency
                checkboxFrame.Label.TextTransparency = transparency
            end)
            effect(function()
                local on = isChecked()
                checkboxFrame.CheckButton.BackgroundColor3 = on
                    and Color3.fromRGB(200, 200, 200)
                    or Color3.fromRGB(30, 30, 30)
                checkboxFrame.CheckButton.Knob.BackgroundColor3 = on
                    and Color3.fromRGB(20, 20, 20)
                    or Color3.fromRGB(90, 90, 90)
                checkboxFrame.CheckButton.Knob.Position = on
                    and UDim2.new(1, -14, 0.5, 0)
                    or UDim2.new(0, 2, 0.5, 0)
            end)

            if not childs then return checkboxFrame end

            return create'Frame'{
                BackgroundTransparency = 1,
                Size = UDim2.fromScale(1, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                create'UIListLayout'{
                    HorizontalAlignment = Enum.HorizontalAlignment.Left,
                    VerticalAlignment = Enum.VerticalAlignment.Top,
                    FillDirection = Enum.FillDirection.Vertical,
                },
                checkboxFrame,
                vide.indexes(childs, function(child, i)
                    return create'Frame'{
                        Size = UDim2.fromScale(1, 0),
                        AutomaticSize = Enum.AutomaticSize.Y,
                        BackgroundTransparency = 1,
                        create'UIListLayout'{
                            Padding = UDim.new(0, 4),
                            HorizontalAlignment = Enum.HorizontalAlignment.Left,
                            VerticalAlignment = Enum.VerticalAlignment.Center,
                            FillDirection = Enum.FillDirection.Horizontal,
                            HorizontalFlex = Enum.UIFlexAlignment.Fill,
                        },
                        TreeChildTrail({ isFinalizer = i == #childs() }),
                        child(),
                    }
                end),
            }
        end

        return Checkbox
    end
    function __DARKLUA_BUNDLE_MODULES.Q()
        local Segment = {}

        function Segment.GenerateCirclePoints(centerPosition, radius, resolution)
            local circumference = 2 * math.pi * radius
            local numPoints = math.max(3, math.floor(circumference / resolution))
            local angleStep = (2 * math.pi) / numPoints
            local points = {}
            for i = 0, numPoints - 1 do
                local angle = i * angleStep
                local x = centerPosition.X + radius * math.cos(angle)
                local z = centerPosition.Z + radius * math.sin(angle)
                table.insert(points, Vector3.new(x, centerPosition.Y, z))
            end
            return points, numPoints
        end

        return Segment
    end
    function __DARKLUA_BUNDLE_MODULES.R()
        local Animal = __DARKLUA_BUNDLE_MODULES.load('I')
        local ReplicatedStorage = game:GetService('ReplicatedStorage')
        local AskServerToSetSubStateRemoteFunction = ReplicatedStorage:WaitForChild('AskServerToSetSubStateRemoteFunction')
        local namecall
        local blockChangeSubState = false

        namecall = hookmetamethod(game, '__namecall', function(self, ...)
            if blockChangeSubState then
                local isTryingToChangeSubState = self == AskServerToSetSubStateRemoteFunction
                if isTryingToChangeSubState and not checkcaller() then
                    return true
                end
            end
            return namecall(self, ...)
        end)

        local function SetClientSubStateChangesEnabled(enabled)
            blockChangeSubState = not enabled
        end
        local function ChangeCharacterSubState(state)
            task.spawn(AskServerToSetSubStateRemoteFunction.InvokeServer, AskServerToSetSubStateRemoteFunction, state)
        end

        local Utils = require(ReplicatedStorage:WaitForChild('AnimalGameFrameworkShared'):WaitForChild('Utils'))
        local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)

        local function CanStartEatDrink(p94, p95)
            if not p94 then return end
            if p94:GetAttribute('IsCarrying') then return end
            if not p95 and p94:GetAttribute('MovementDisabled') then return end
            if not p94:FindFirstChild('Head') then return end
            local v96 = p94:GetAttribute('AnimalType')
            local v97 = p94:GetAttribute('AnimalName')
            if not (v96 and v97 and p94:GetAttribute('AnimalAge')) then
                warn("Not spawned as animal, so we can't check eat/drink")
                return
            end
            local v98 = AnimalConfig[v96][v97]
            local v99 = Utils.CanEatDrink.DetectMeatGrassWater(p94, v98)
            return v98.EnableLeavesEating and Utils.DetectLeaves(p94)
                or (v98.EnableInsectEating and Utils.DetectInsects(p94) or v99)
        end

        local grassResolution   = 4
        local grassHeightOffset = Vector3.new(0, 40, 0)
        local grassRayDirection = Vector3.new(0, -80, 0)
        local SegmentCircle     = __DARKLUA_BUNDLE_MODULES.load('Q')
        local Grass             = Enum.Material.Grass
        local grassRayParams    = RaycastParams.new()
        grassRayParams.FilterType = Enum.RaycastFilterType.Include
        grassRayParams.FilterDescendantsInstances = { workspace.Terrain }
        local grassStartingRadius = 6
        local grassMaxRadius      = grassStartingRadius * 8

        local function FindNearestGrass(at, radius)
            local points = SegmentCircle.GenerateCirclePoints(at + grassHeightOffset, radius, grassResolution)
            for _, v in points do
                local result = workspace:Raycast(v, grassRayDirection, grassRayParams)
                if result and result.Material == Grass then return result.Position end
            end
            if radius == grassMaxRadius then return end
            return FindNearestGrass(at, radius * 2)
        end

        local waterResolution   = 12
        local waterHeightOffset = Vector3.new(0, 80, 0)
        local waterRayDirection = Vector3.new(0, -160, 0)
        local Water             = Enum.Material.Water
        local waterRayParams    = RaycastParams.new()
        waterRayParams.FilterType = Enum.RaycastFilterType.Include
        waterRayParams.FilterDescendantsInstances = { workspace.Terrain }
        local waterStartingRadius = 12
        local waterMaxRadius      = 384

        local function FindNearestWaterShore(at, radius)
            local points = SegmentCircle.GenerateCirclePoints(at + waterHeightOffset, radius, waterResolution)
            local bestPosition, bestDistance = nil, math.huge
            for _, v in points do
                local result = workspace:Raycast(v, waterRayDirection, waterRayParams)
                if result and result.Material == Water then
                    local flatDir  = Vector3.new(result.Position.X - at.X, 0, result.Position.Z - at.Z)
                    local flatDist = flatDir.Magnitude
                    local shore    = result.Position
                    if flatDist > 0 then shore = result.Position - flatDir.Unit * math.min(2, flatDist) end
                    if flatDist < bestDistance then bestDistance = flatDist bestPosition = shore end
                end
            end
            if bestPosition then return bestPosition end
            if radius >= waterMaxRadius then return end
            return FindNearestWaterShore(at, math.min(radius * 2, waterMaxRadius))
        end

        local player   = game:GetService('Players').LocalPlayer
        local Checkbox = __DARKLUA_BUNDLE_MODULES.load('M')
        local vide     = __DARKLUA_BUNDLE_MODULES.load('x')
        local source   = vide.source

        local goToNearestSource     = source(true)
        local autoEatChecked        = source(false)
        local autoDrinkChecked      = source(false)
        local autoEatCarcassChecked = source(false)
        shared._autoEatChecked        = autoEatChecked
        shared._autoDrinkChecked      = autoDrinkChecked
        shared._autoEatCarcassChecked = autoEatCarcassChecked

        local lastDrinkMoveAt     = 0
        local DRINK_MOVE_COOLDOWN = 1.5
local function getWaterVerticalGoal(rootPosition)
    local waterPart = workspace:FindFirstChild("MainWaterPart")
    if waterPart and waterPart:IsA("BasePart") then
        return CFrame.new(rootPosition.X, waterPart.Position.Y + 2, rootPosition.Z)
    end
    local wp = FindNearestWaterShore(rootPosition, waterStartingRadius)
    if wp then return CFrame.new(rootPosition.X, wp.Y + 2, rootPosition.Z) end
end
        -- ============================================================
        -- CARCASS HELPERS
        -- ============================================================
        local CARNIVORES = {
            Lion=true, Tiger=true, Cheetah=true,
            Crocodile=true, Leopard=true, ["T-Rex"]=true, TRex=true,
        }

        local function findEatRemote()
            local names = {
                "StartEatingCarcassesRemotEvent",
                "StartEatingCarcassRemoteEvent",
                "EatCarcassRemoteEvent",
                "CarcassEatRemoteEvent",
                "StartEatingDeadAnimalRemoteEvent",
            }
            for _, name in names do
                local r = ReplicatedStorage:FindFirstChild(name, true)
                if r then return r end
            end
            return nil
        end

        local function findCarcassStorage()
            local candidates = {
                "CarcassesStorageModel","CarcassStorage","Carcasses",
                "DeadAnimals","DeadAnimalStorage","CarcassModel",
                "DeadDinosaurs","DinosaurCarcasses","MeatStorage",
            }
            for _, name in candidates do
                local found = workspace:FindFirstChild(name)
                if found then return found end
            end
            for _, child in workspace:GetChildren() do
                if child:IsA("Model") or child:IsA("Folder") then
                    for _, desc in child:GetChildren() do
                        if desc:IsA("Model") and desc:FindFirstChild("HumanoidRootPart") then return child end
                    end
                    for _, desc in child:GetDescendants() do
                        if desc:IsA("Model") and desc:FindFirstChild("HumanoidRootPart") then return desc.Parent end
                    end
                end
            end
            for _, desc in workspace:GetDescendants() do
                if desc:IsA("Model") and desc:FindFirstChild("HumanoidRootPart") then
                    local n = desc.Name:lower()
                    if n:find("carcass") or n:find("dead") or n:find("meat") then return desc.Parent end
                end
            end
            return nil
        end

        local function getCarcassRoot(c)
            return c:FindFirstChild("HumanoidRootPart")
                or c:FindFirstChildWhichIsA("BasePart", true)
        end

        local carcassEatBusy = false
        local lastEatEndTime = 0
        local EAT_COOLDOWN   = 6
        local TP_TOLERANCE   = 12
        local subStateRF     = ReplicatedStorage:WaitForChild("AskServerToSetSubStateRemoteFunction", 10)

        local RAGDOLL_STATES = {
            [Enum.HumanoidStateType.Physics]     = true,
            [Enum.HumanoidStateType.FallingDown] = true,
            [Enum.HumanoidStateType.Ragdoll]     = true,
            [Enum.HumanoidStateType.Freefall]    = true,
            [Enum.HumanoidStateType.GettingUp]   = true,
        }

        local function ragdollTeleportToPos(character, targetPos, maxAttempts)
            maxAttempts = maxAttempts or 6
            for attempt = 1, maxAttempts do
                local root = character:FindFirstChild("HumanoidRootPart")
                local hum  = character:FindFirstChild("Humanoid")
                if not root or not hum then task.wait(1) continue end
                Animal.CancelTween(true)
                root.Anchored = false
                hum:ChangeState(Enum.HumanoidStateType.Physics)
                for _ = 1, 25 do
                    if character:FindFirstChild("HumanoidRootPart") then
                        character:SetPrimaryPartCFrame(CFrame.new(targetPos))
                    end
                    task.wait()
                end
                task.wait(1)
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                for _ = 1, 10 do character:SetAttribute("MovementDisabled", false) task.wait(0.1) end
                local r = character:FindFirstChild("HumanoidRootPart")
                if r then
                    local dist = (r.Position - targetPos).Magnitude
                    if dist <= TP_TOLERANCE then return true end
                    warn(string.format("[CarcassEat] Too far %.1f studs — retrying", dist))
                end
            end
            warn("[CarcassEat] TP failed after " .. maxAttempts .. " attempts")
            return false
        end

local function carcassWhileChecked()
            if carcassEatBusy then return end
            if (tick() - lastEatEndTime) < EAT_COOLDOWN then return end
            if shared._inGrowthReset then return end

            local character = player.Character
            if not character then return end

            local curWater = character:GetAttribute("Water") or 100
            if curWater <= 30 then
                character:SetAttribute('_drinkingToFull', true)
                return false
            end

            local growth = character:GetAttribute("GrowthPercentage") or 0
            if growth >= 1 then return false end

            local animalName = character:GetAttribute("AnimalName") or ""
            if not CARNIVORES[animalName] then return false end

            local food = character:GetAttribute("Food") or 0
            if food >= 90 then return false end

            local eatRemote = findEatRemote()
            if not eatRemote then warn("[CarcassEat] No eat remote found") return false end

            local carcassStorage = findCarcassStorage()
            if not carcassStorage then warn("[CarcassEat] No carcass storage") return false end

            local root = character:FindFirstChild("HumanoidRootPart")
            if not root then return end

            local nearest, nearestDist = nil, math.huge
            local MAX_RANGE = 2500

            for _, c in carcassStorage:GetDescendants() do
                if c:IsA("Model") and c:FindFirstChild("HumanoidRootPart") then
                    local r = getCarcassRoot(c)
                    if r then
                        local dist = (root.Position - r.Position).Magnitude
                        if dist < nearestDist and dist < MAX_RANGE then
                            nearest = c
                            nearestDist = dist
                        end
                    end
                end
            end
            for _, desc in workspace:GetDescendants() do
                if desc:IsA("Model") and desc:FindFirstChild("HumanoidRootPart") then
                    local n = desc.Name:lower()
                    if (n:find("carcass") or n:find("dead")) and desc.Parent ~= carcassStorage then
                        local r = getCarcassRoot(desc)
                        if r then
                            local dist = (root.Position - r.Position).Magnitude
                            if dist < nearestDist and dist < MAX_RANGE then nearest = desc nearestDist = dist end
                        end
                    end
                end
            end

            if not nearest then return false end
            local cRoot = getCarcassRoot(nearest)
            if not cRoot then return false end

            carcassEatBusy       = true
            shared._inCarcassEat = true
            print("[CarcassEat] Target:", nearest.Name, "| dist:", math.floor(nearestDist), "| food:", food)

            character:SetAttribute('_drinkingToFull', false)
            Animal.CancelTween(true)

            local standPos = Vector3.new(cRoot.Position.X, cRoot.Position.Y + 2, cRoot.Position.Z)
            ragdollTeleportToPos(character, standPos)
            task.wait(0.4)

            local anchorRoot = character:FindFirstChild("HumanoidRootPart")
            if anchorRoot then anchorRoot.Anchored = true end

            local hum = character:FindFirstChild("Humanoid")
            if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) task.wait(0.2) end

            SetClientSubStateChangesEnabled(false)
            pcall(function() subStateRF:InvokeServer("Eating") end)
            task.wait(0.3)
            pcall(function() eatRemote:FireServer(nearest) end)

            local startFood      = character:GetAttribute("Food") or 0
            local anchorReleased = false
            local foodRose       = false
            local releaseDeadline = tick() + 5

            while not anchorReleased do
                task.wait(0.15)
                local curChar = player.Character
                if not curChar or curChar ~= character then break end
                local curHum  = curChar:FindFirstChildOfClass("Humanoid")
                local curFood = curChar:GetAttribute("Food") or 0
                if curFood > startFood then foodRose = true end
                pcall(function() eatRemote:FireServer(nearest) end)
                if curHum and RAGDOLL_STATES[curHum:GetState()] then
                    curHum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
                if curHum and foodRose and not RAGDOLL_STATES[curHum:GetState()] then
                    local relRoot = curChar:FindFirstChild("HumanoidRootPart")
                    if relRoot then
                        Animal.CancelTween(true)
                        relRoot.AssemblyLinearVelocity  = Vector3.zero
                        relRoot.AssemblyAngularVelocity = Vector3.zero
                        relRoot.Anchored = false
                    end
                    anchorReleased = true
                elseif tick() > releaseDeadline then
                    local relRoot = curChar:FindFirstChild("HumanoidRootPart")
                    if relRoot then
                        Animal.CancelTween(true)
                        relRoot.AssemblyLinearVelocity  = Vector3.zero
                        relRoot.AssemblyAngularVelocity = Vector3.zero
                        relRoot.Anchored = false
                    end
                    anchorReleased = true
                    warn("[CarcassEat] Safety anchor release")
                end
            end

            local lastFood2  = character:GetAttribute("Food") or 0
            local stallTicks = 0
            local MAX_STALL  = 6

            while true do
                task.wait(0.5)
                local curChar = player.Character
                if not curChar or curChar ~= character then break end
                local curFood = curChar:GetAttribute("Food") or 0
                if curFood >= 95 then print("[CarcassEat] Full") break end
                if curFood > lastFood2 then
                    lastFood2  = curFood
                    stallTicks = 0
                    pcall(function() eatRemote:FireServer(nearest) end)
                else
                    stallTicks = stallTicks + 1
                    if stallTicks >= MAX_STALL then print("[CarcassEat] Stalled at", curFood) break end
                end
                if not nearest.Parent then print("[CarcassEat] Carcass gone") break end
            end

            SetClientSubStateChangesEnabled(true)
            task.wait(0.5)

            local safetyRoot = character:FindFirstChild("HumanoidRootPart")
            if safetyRoot and safetyRoot.Anchored then
                Animal.CancelTween(true)
                safetyRoot.AssemblyLinearVelocity  = Vector3.zero
                safetyRoot.AssemblyAngularVelocity = Vector3.zero
                safetyRoot.Anchored = false
            end

            if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
            for _ = 1, 5 do character:SetAttribute("MovementDisabled", false) task.wait(0.1) end

            shared._inCarcassEat = false
            lastEatEndTime       = tick()
            carcassEatBusy       = false
        end

        -- ============================================================
        -- CHECKBOXES
        -- ============================================================
        return {
            Checkbox({
                label = 'Auto eat',
                isChecked = autoEatChecked,
                controlPriority = {character = 2},
                WhileChecked = function()
                    local character = player.Character
                    if not character then return end
                    if shared._inGrowthReset then return false end
                    if shared._inCarcassEat then return false end
                    local animalName = character:GetAttribute("AnimalName") or ""
                    if CARNIVORES[animalName] then return false end
                    if character:GetAttribute('_drinkingToFull') then return end
                    if (character:GetAttribute('Food') or 0) <= 90 then
                        local ingestionAvaliable = CanStartEatDrink(character)
                        if ingestionAvaliable == 'Eat' then
                            SetClientSubStateChangesEnabled(false)
                            ChangeCharacterSubState('Eating')
                        elseif goToNearestSource() then
                            local root = character:FindFirstChild("HumanoidRootPart")
                            if not root then return end
                            local grassPosition = FindNearestGrass(root.Position, grassStartingRadius)
                            if not grassPosition then return end
                            local humanoid = character:FindFirstChild("Humanoid")
                            if not humanoid then return end
                            local goalPosition = grassPosition + Vector3.new(0, humanoid.HipHeight, 0)
                            local direction = goalPosition - root.Position
                            Animal.TweenToAsync(CFrame.lookAlong(goalPosition - direction.Unit, direction))
                        else
                            return false
                        end
                    else
                        return false
                    end
                end,
            }),

            Checkbox({
                label = 'Auto eat carcass',
                isChecked = autoEatCarcassChecked,
                controlPriority = {character = 2},
                WhileChecked = carcassWhileChecked,
            }),

            Checkbox({
                label = 'Auto drink',
                isChecked = autoDrinkChecked,
                controlPriority = {character = 3},
                WhileChecked = function()
                    local character = player.Character
                    if not character then return end
                    if shared._inGrowthReset then
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end
                    if shared._inCarcassEat then
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end
                    local growth = character:GetAttribute("GrowthPercentage") or 0
                    if growth >= 1 and not shared._parkingModeActive then
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end
                    local water = character:GetAttribute('Water') or 0
                    if water <= 90 then character:SetAttribute('_drinkingToFull', true) end
                    if water >= 100 then
                        local animalName = character:GetAttribute("AnimalName") or ""
                        if (animalName == "Lion" or animalName == "Tiger") and shared._growSpawn then
                            local root = character:FindFirstChild("HumanoidRootPart")
                            local hum  = character:FindFirstChild("Humanoid")
                            if root and hum then
                                root.Anchored = false
                                hum:ChangeState(Enum.HumanoidStateType.Physics)
                                for _ = 1, 25 do
                                    local r = character:FindFirstChild("HumanoidRootPart")
                                    if r then character:SetPrimaryPartCFrame(CFrame.new(shared._growSpawn)) end
                                    task.wait()
                                end
                                task.wait(0.5)
                                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                                for _ = 1, 6 do character:SetAttribute("MovementDisabled", false) task.wait(0.1) end
                            end
                            character:SetAttribute('_drinkingToFull', false)
                            return false
                        end
                        Animal.CancelTween(true)
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end
                    if not character:GetAttribute('_drinkingToFull') then return false end
                    local ingestionAvaliable = CanStartEatDrink(character, true)
                    if ingestionAvaliable == 'Eat' then ingestionAvaliable = nil end
                    if ingestionAvaliable == 'Drink' then
                        Animal.CancelTween(true)
                        SetClientSubStateChangesEnabled(false)
                        ChangeCharacterSubState('Drinking')
                    elseif goToNearestSource() then
                        local root     = character:FindFirstChild("HumanoidRootPart")
                        local humanoid = character:FindFirstChild("Humanoid")
                        if not root then return end
                        if root.Anchored then root.Anchored = false end
                        if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end
                        local waterGoal = getWaterVerticalGoal(root.Position)
if waterGoal then
    local humanoid = character:FindFirstChild("Humanoid")
    local hipHeight = humanoid and humanoid.HipHeight or 3
    -- lift goal above water surface so character doesn't clip in
    local liftedGoal = CFrame.new(
        waterGoal.Position.X,
        waterGoal.Position.Y + hipHeight + 1.5,
        waterGoal.Position.Z
    )
    local dist = (liftedGoal.Position - root.Position).Magnitude
    if dist > 1 and tick() - lastDrinkMoveAt >= DRINK_MOVE_COOLDOWN then
        lastDrinkMoveAt = tick()
        Animal.TweenToAsync(liftedGoal)
    else
        task.wait(0.25)
    end
                        else
                            return false
                        end
                    else
                        return false
                    end
                end,
            }),

            Checkbox({
                label = 'Go to nearest food/water source',
                isChecked = goToNearestSource,
            }),
        }
    end
    function __DARKLUA_BUNDLE_MODULES.S()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local source = vide.source
        local Animal = __DARKLUA_BUNDLE_MODULES.load('I')
        local Checkbox = __DARKLUA_BUNDLE_MODULES.load('M')
        local player = game:GetService('Players').LocalPlayer

        return {
            Checkbox({
                label = 'Automatically leave from inside terrain',
                isChecked = true,
                controlPriority = {character = 1},
                WhileChecked = (function()
                    local lionTerrainStreak = 0
                    local LION_TERRAIN_REQUIRED = 5
                    return function()
                        local character = player.Character
                        if not character then return end
                        local root = character:FindFirstChild("HumanoidRootPart")
                        if not root then return end
                        if shared._animalTweening then lionTerrainStreak = 0 return false end
                        local animalName = character:GetAttribute("AnimalName") or ""
                        local isLionOrTiger = (animalName == "Lion" or animalName == "Tiger")
                        if Animal.IsInsideTerrain() then
                            if isLionOrTiger then
                                lionTerrainStreak = lionTerrainStreak + 1
                                if lionTerrainStreak < LION_TERRAIN_REQUIRED then return end
                                lionTerrainStreak = 0
                                root.CFrame = CFrame.new(root.Position + Vector3.new(0, 8, 0))
                            else
                                lionTerrainStreak = 0
                                root.CFrame = CFrame.new(root.Position + Vector3.new(0, 4, 0))
                            end
                        else
                            lionTerrainStreak = 0
                            return false
                        end
                    end
                end)(),
            }),
            Checkbox({
                label = 'Grow new slots',
                isChecked = source(false),
                OnChanged = function(state)
                    if shared._setGrowNewSlots then shared._setGrowNewSlots(state) end
                end,
            }),
            Checkbox({
                label = 'Grow existing slots',
                isChecked = source(false),
                OnChanged = function(state)
                    if shared._setGrowExistingSlots then shared._setGrowExistingSlots(state) end
                end,
            }),
            Checkbox({
                label = 'Passive coins (parking mode)',
                isChecked = source(false),
                OnChanged = function(state)
                    if shared._setParkingMode then shared._setParkingMode(state) end
                end,
            }),
        }
    end
    function __DARKLUA_BUNDLE_MODULES.T()
        local icons = __DARKLUA_BUNDLE_MODULES.load('E')
        return {
            icon = icons.untitled.icons['user-02'],
            sections = {
                { name = 'Eat-drink', content = __DARKLUA_BUNDLE_MODULES.load('R') },
                { name = 'Misc',      content = __DARKLUA_BUNDLE_MODULES.load('S') },
            },
        }
    end
    function __DARKLUA_BUNDLE_MODULES.X()
        return {
            categories = {
                __DARKLUA_BUNDLE_MODULES.load('T'),
            },
        }
    end
end

local vide     = __DARKLUA_BUNDLE_MODULES.load('x')
local source   = vide.source
local create   = vide.create
local root     = vide.root
local Window   = __DARKLUA_BUNDLE_MODULES.load('C')
local Category = __DARKLUA_BUNDLE_MODULES.load('G')

function App()
    local categories        = {}
    local containers        = {}
    local isOpenedSources   = {}

    for i, v in __DARKLUA_BUNDLE_MODULES.load('X').categories do
        local isOpened = source(i == 1)
        isOpenedSources[i] = isOpened
        local category, container = Category({
            icon = v.icon,
            isOpened = isOpened,
            sections = v.sections,
        })
        categories[i] = category
        containers[i] = container
    end

    return create'ScreenGui'{
        Window{
            categories = categories,
            containers = containers,
            isOpenedSources = isOpenedSources,
        },
    }
end

if not game:IsLoaded() then game.Loaded:Wait() end

local destroy
destroy = root(function()
    local app = App()
    app.Parent = game:GetService('CoreGui')
    app.ZIndexBehavior = Enum.ZIndexBehavior.Global
    shared.LECleanup = function()
        destroy()
        app:Destroy()
    end
    task.defer(function()
        local win = app:FindFirstChild("Frame1", true)
        if win and win:IsA("Frame") then
            win.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
            local g = Instance.new("UIGradient")
            g.Color = ColorSequence.new{
                ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 40, 40)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 6, 6)),
            }
            g.Rotation = 130
            g.Parent = win
        end
    end)
end)

-- Anti-AFK layer 1
task.spawn(function()
    local VirtualUser = game:GetService("VirtualUser")
    game:GetService("Players").LocalPlayer.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end)

-- Anti-AFK layer 2
task.spawn(function()
    local VirtualUser = game:GetService("VirtualUser")
    local camera = workspace.CurrentCamera
    while true do
        task.wait(240)
        pcall(function()
            local cf = camera.CFrame
            camera.CFrame = cf * CFrame.Angles(0, math.rad(0.5), 0)
            task.wait(0.1)
            camera.CFrame = cf
        end)
        pcall(function()
            VirtualUser:Button2Down(Vector2.new(0, 0), camera.CFrame)
            task.wait(0.1)
            VirtualUser:Button2Up(Vector2.new(0, 0), camera.CFrame)
        end)
        pcall(function()
            VirtualUser:KeyDown(0x57)
            task.wait(0.1)
            VirtualUser:KeyUp(0x57)
        end)
    end
end)

-- Inf Stamina
task.spawn(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local player     = Players.LocalPlayer
    RunService.Heartbeat:Connect(function()
        if player.Character then
            pcall(function() player.Character:SetAttribute("Stamina", 100) end)
        end
    end)
end)

-- Always Daytime
task.spawn(function()
    local RunService = game:GetService("RunService")
    local Lighting   = game:GetService("Lighting")
    RunService.Heartbeat:Connect(function()
        Lighting.ClockTime = 12
    end)
end)

-- Auto Growth Loop
task.spawn(function()
    local Players       = game:GetService("Players")
    local RS            = game:GetService("ReplicatedStorage")
    local CoreGui       = game:GetService("CoreGui")
    local RunService    = game:GetService("RunService")
    local player        = Players.LocalPlayer

    local GAME_CONFIGS = {
        [6174994284] = {
            name           = "SavannahLife",
            expectedAnimal = "Elephant",
            growSpawn      = Vector3.new(-6245.2, 10.0, 4664.3),
            warSpawn       = Vector3.new(-6245.2, 10.0, 4664.3),
            safePos        = Vector3.new(-6245.2, 10.0, 4664.3),
            dangerY        = -100,
            babySpawnArgs  = { Elephant="Elephant", Lion="Lion", Giraffe="Giraffe", Hippo="Hippo", Rhino="Rhino", Impala="Impala" },
        },
        [18214855317] = {
            name           = "SavannahLife",
            expectedAnimal = "Elephant",
            growSpawn      = Vector3.new(-6245.2, 10.0, 4664.3),
            warSpawn       = Vector3.new(-6245.2, 10.0, 4664.3),
            safePos        = Vector3.new(-6245.2, 10.0, 4664.3),
            dangerY        = -100,
            babySpawnArgs  = { Elephant="Elephant", Lion="Lion", Giraffe="Giraffe", Hippo="Hippo", Rhino="Rhino", Impala="Impala" },
        },
        [9237322219] = {
            name           = "JungleLife",
            expectedAnimal = "Gorilla",
            growSpawn      = Vector3.new(1166.835, 24.751, -358.321),
            warSpawn       = Vector3.new(1166.835, 24.751, -358.321),
            safePos        = Vector3.new(1166.835, 24.751, -358.321),
            dangerY        = -100,
            babySpawnArgs  = { Gorilla="Gorilla" },
        },
        [75541741887441] = {
            name           = "DinosaurLife",
            expectedAnimal = "T-Rex",
            growSpawn      = Vector3.new(-26.318, 59.041, 190.665),
            warSpawn       = Vector3.new(-26.318, 59.041, 190.665),
            safePos        = Vector3.new(-26.318, 59.041, 190.665),
            dangerY        = -100,
            babySpawnArgs  = { ["T-Rex"]="T-Rex", TRex="TRex" },
        },
    }

    local function detectConfigByAnimal()
        local deadline = tick() + 15
        while tick() < deadline do
            local ch = player.Character
            if ch then
                local animal = ch:GetAttribute("AnimalName")
                if animal and animal ~= "" then
                    local JUNGLE   = { Gorilla=true, Chimpanzee=true, Leopard=true, Mandrill=true }
                    local SAVANNAH = { Elephant=true, Lion=true, Giraffe=true, Hippo=true, Rhino=true, Impala=true, Zebra=true, Cheetah=true, Hyena=true, Wildbeest=true }
                    local DINO     = { ["T-Rex"]=true, TRex=true }
                    if JUNGLE[animal]   then return GAME_CONFIGS[9237322219] end
                    if SAVANNAH[animal] then return GAME_CONFIGS[18214855317] end
                    if DINO[animal]     then return GAME_CONFIGS[75541741887441] end
                    warn("[GrowthLoop] Unknown animal: " .. tostring(animal))
                    return nil
                end
            end
            task.wait(0.5)
        end
        warn("[GrowthLoop] Animal-detection timed out")
        return nil
    end

    local gameConfig = GAME_CONFIGS[game.GameId]
    if not gameConfig then
        warn("[GrowthLoop] GameId not recognised — detecting by animal")
        gameConfig = detectConfigByAnimal()
        if not gameConfig then
            warn("[GrowthLoop] Detection failed — defaulting to SavannahLife")
            gameConfig = GAME_CONFIGS[18214855317]
        end
    end
    shared._growthGameName = gameConfig.name
    print("[GrowthLoop] Detected game: " .. gameConfig.name)

    local growNewSlots      = false
    local growExistingSlots = false
    local MAX_SLOTS              = 40
    local slotsGrownThisCycle    = 0
    local allExistingGrown       = false
    local parkingMode            = false
    shared._parkingModeActive    = false

    local function setParkingModeState(state)
        parkingMode = state
        shared._parkingModeActive = state
    end

    shared._setGrowNewSlots = function(state)
        growNewSlots = state
        print("[GrowthLoop] Grow new slots:", state)
    end
    shared._setGrowExistingSlots = function(state)
        growExistingSlots = state
        print("[GrowthLoop] Grow existing slots:", state)
    end
    local pendingParkMode = false
    shared._setParkingMode = function(state)
        setParkingModeState(state)
        print("[GrowthLoop] Parking mode:", state)
        if state then
            pendingParkMode = true
            if shared._runParkingMode then
                pendingParkMode = false
                task.spawn(shared._runParkingMode)
            end
        else
            pendingParkMode = false
        end
    end

    local existingSlots      = {}
    local originalSlotCount  = 0
    local trackedSlots       = {}
    local trackedSlotLookup  = {}
    local existingSlotIndex  = 1

    local function findSlotIndexByName(name, pool)
        if not name then return nil end
        pool = pool or trackedSlots
        for i, v in ipairs(pool) do
            if v == name then return i end
        end
        return nil
    end

    local function getTrackedSlotTotal()
        return math.min(#trackedSlots, MAX_SLOTS)
    end

    local function trackSlotName(name)
        if not name then return false end
        if trackedSlotLookup[name] then return false end
        if #trackedSlots >= MAX_SLOTS then
            warn("[GrowthLoop] Tracked slot list at max — skipping:", name)
            return false
        end
        table.insert(trackedSlots, name)
        trackedSlotLookup[name] = true
        return true
    end

    local poolIndexes = {}
    local function getPoolIndex(pool) return poolIndexes[pool] or 1 end
    local function advancePoolIndex(pool)
        local cur = getPoolIndex(pool)
        poolIndexes[pool] = (cur % #pool) + 1
    end

    local getUniqueName
    local removeName

    do
        local ALLOWED_EXISTING_ANIMALS_BY_GAME = {
            SavannahLife = { Elephant=true, Lion=true, Giraffe=true, Hippo=true, Rhino=true, Impala=true, Zebra=true, Cheetah=true, Hyena=true, Wildbeest=true },
            JungleLife   = { Gorilla=true, Chimpanzee=true, Leopard=true, Mandrill=true, Tiger=true, Lion=true },
            DinosaurLife = { ["T-Rex"]=true },
        }

        local savedSlotRecords               = {}
        local lastSavedCharacterRefresh      = 0
        local SAVE_REFRESH_INTERVAL          = 1
        local warnedMissingSavedCharactersAPI = false
        local warnedSavedCharactersReadFailed = false

        existingSlots     = {}
        originalSlotCount = 0
        trackedSlots      = {}
        trackedSlotLookup = {}
        existingSlotIndex = 1

        local function isPlayerDataReplication(candidate)
            return type(candidate) == "table" and type(candidate.GetKeyData) == "function"
        end

        local function resolvePlayerDataReplication()
            local cached = shared._playerDataReplication
            if isPlayerDataReplication(cached) then return cached end
            local directCandidates = { shared.PlayerDataReplication, _G.PlayerDataReplication }
            if type(getgenv) == "function" then
                local ok, env = pcall(getgenv)
                if ok and type(env) == "table" then table.insert(directCandidates, env.PlayerDataReplication) end
            end
            for _, candidate in ipairs(directCandidates) do
                if isPlayerDataReplication(candidate) then
                    shared._playerDataReplication = candidate
                    return candidate
                end
            end
            local searchRoots = { RS, player:FindFirstChild("PlayerScripts"), player:FindFirstChild("PlayerGui") }
            for _, searchRoot in ipairs(searchRoots) do
                if searchRoot then
                    local moduleScript = searchRoot:FindFirstChild("PlayerDataReplication", true)
                    if moduleScript and moduleScript:IsA("ModuleScript") then
                        local ok, result = pcall(require, moduleScript)
                        if ok and isPlayerDataReplication(result) then
                            shared._playerDataReplication = result
                            return result
                        end
                    end
                end
            end
            return nil
        end

        local function findSavedCharactersMenu()
            local cached = shared._savedCharactersMenu
            if typeof(cached) == "Instance" and cached.Parent then return cached end
            local playerGui = player:FindFirstChildOfClass("PlayerGui")
            local menu = (playerGui and playerGui:FindFirstChild("SavedCharactersMenu", true))
                or CoreGui:FindFirstChild("SavedCharactersMenu", true)
            if menu then shared._savedCharactersMenu = menu end
            return menu
        end

        local function setSelectedSavedCharacterName(name)
            if type(name) ~= "string" or name == "" then return end
            local menu = findSavedCharactersMenu()
            if menu then pcall(function() menu:SetAttribute("UniqueCharacterName", name) end) end
        end

        local function rebuildTrackedFromRecords(records)
            trackedSlots      = {}
            trackedSlotLookup = {}
            for _, entry in ipairs(records) do
                local name = entry.CharacterName
                if type(name) == "string" and name ~= "" and not trackedSlotLookup[name] then
                    table.insert(trackedSlots, name)
                    trackedSlotLookup[name] = true
                end
            end
        end

        local function syncSavedCharacterRecords(force)
            local now = tick()
            if not force and (now - lastSavedCharacterRefresh) < SAVE_REFRESH_INTERVAL then
                return savedSlotRecords
            end
            lastSavedCharacterRefresh = now
            local replication = resolvePlayerDataReplication()
            if not replication then
                if not warnedMissingSavedCharactersAPI then
                    warnedMissingSavedCharactersAPI = true
                    warn("[GrowthLoop] PlayerDataReplication not found")
                end
                return savedSlotRecords
            end
            local ok, rawList = pcall(function() return replication.GetKeyData("SavedCharacters") end)
            if not ok or type(rawList) ~= "table" then
                if not warnedSavedCharactersReadFailed then
                    warnedSavedCharactersReadFailed = true
                    warn("[GrowthLoop] Failed to read SavedCharacters")
                end
                return savedSlotRecords
            end
            warnedSavedCharactersReadFailed = false
            local allowedAnimals = ALLOWED_EXISTING_ANIMALS_BY_GAME[gameConfig.name]
            local nextRecords = {}
            local nextNames   = {}
            local seen        = {}
            for _, entry in ipairs(rawList) do
                if type(entry) == "table" then
                    local charName   = entry.CharacterName
                    local animalName = entry.AnimalName
                    if type(charName) == "string" and charName ~= ""
                        and type(animalName) == "string" and animalName ~= ""
                        and (not allowedAnimals or allowedAnimals[animalName])
                        and not seen[charName]
                    then
                        table.insert(nextRecords, entry)
                        table.insert(nextNames, charName)
                        seen[charName] = true
                        if #nextRecords >= MAX_SLOTS then break end
                    end
                end
            end
            savedSlotRecords = nextRecords
            existingSlots    = nextNames
            rebuildTrackedFromRecords(nextRecords)
            if #existingSlots == 0 or existingSlotIndex > #existingSlots then existingSlotIndex = 1 end
            if originalSlotCount == 0 and #existingSlots > 0 then originalSlotCount = #existingSlots end
            return savedSlotRecords
        end

        local function findSavedCharacterRecordByName(name, records)
            if type(name) ~= "string" or name == "" then return nil end
            records = records or syncSavedCharacterRecords()
            for _, entry in ipairs(records) do
                if entry.CharacterName == name then return entry end
            end
            return nil
        end

        local function getFirstExistingSlotRecord()
            local records = syncSavedCharacterRecords(true)
            return records[1]
        end

        local function getNextExistingSlotRecord()
            local records = syncSavedCharacterRecords(true)
            if #records == 0 then return nil, nil, 0 end
            local idx
            local currentIdx = findSlotIndexByName(shared._currentGrowthName, existingSlots)
            if currentIdx then
                idx = (currentIdx % #records) + 1
            else
                if existingSlotIndex < 1 or existingSlotIndex > #records then existingSlotIndex = 1 end
                idx = existingSlotIndex
            end
            local entry = records[idx]
            existingSlotIndex = (idx % #records) + 1
            return entry, idx, #records
        end

        local function sanitizeNameSeed(text)
            text = tostring(text or ""):gsub("[^%w]+", "")
            if text == "" then text = "Slot" end
            return string.sub(text, 1, 18)
        end

        local newSlotNamePool = {
            "Jack","John","Evian","Aiman","Adam","Alex","Ben","Sam","Max","Leo",
            "Noah","Liam","Omar","Zain","Ali","Ryan","Ethan","Mason","Dylan","Lucas",
            "Harry","Jacob","Henry","Isaac","Yusuf","Amir","Rehan","Arman","Daniel","David",
            "Aaron","Oscar","Toby","Kian","Kai","Jay","Sean","Chris","Kevin","Mark",
        }

        getUniqueName = function(animal)
            local usedNames = {}
            for _, entry in ipairs(syncSavedCharacterRecords(true)) do
                if type(entry.CharacterName) == "string" and entry.CharacterName ~= "" then
                    usedNames[entry.CharacterName] = true
                end
            end
            if animal == "Tiger" or animal == "Elephant" then
                for _, candidate in ipairs(newSlotNamePool) do
                    if not usedNames[candidate] then return candidate end
                end
            end
            local base = sanitizeNameSeed(shared._currentGrowthName or animal or gameConfig.expectedAnimal or "Slot")
            for i = 1, 999 do
                local candidate = string.format("%s%d", base, i)
                if not usedNames[candidate] then return candidate end
            end
            return string.format("%s%d", base, math.floor(os.clock() * 1000))
        end

        removeName = function(name) return nil end

        shared._syncSavedCharacterRecords       = syncSavedCharacterRecords
        shared._findSavedCharacterRecordByName  = findSavedCharacterRecordByName
        shared._getFirstExistingSlotRecord      = getFirstExistingSlotRecord
        shared._getNextExistingSlotRecord       = getNextExistingSlotRecord
        shared._setSelectedSavedCharacterName   = setSelectedSavedCharacterName

        syncSavedCharacterRecords(true)
        if originalSlotCount == 0 then
            warn("[GrowthLoop] WARNING: No valid slots found for", gameConfig.name)
        end
    end

    local isLooping  = false
    local loopToken  = 0

    local function forceUnlockGrowthLoop(reason)
        loopToken = loopToken + 1
        isLooping = false
        shared._inGrowthReset = false
        warn("[GrowthLoop] Force-unlocked: " .. tostring(reason))
    end

    local function withLock(fn)
        if isLooping then return false end
        isLooping = true
        loopToken = loopToken + 1
        local myToken = loopToken
        shared._inGrowthReset = true
        local ok, err = pcall(fn)
        if loopToken == myToken then
            shared._inGrowthReset = false
            isLooping = false
        end
        if not ok then warn("[GrowthLoop] Error:", err) end
        return ok
    end

    local currentGrowthName = nil
    shared._currentGrowthName = nil
    local currentAnimalName = nil
    local currentGender     = nil
    local currentSkin       = nil

    local function waitForAttribute(character, attrName, timeout)
        timeout = timeout or 10
        local waited = 0
        while waited < timeout do
            local val = character:GetAttribute(attrName)
            if val ~= nil then return val end
            task.wait(0.2)
            waited = waited + 0.2
        end
        return nil
    end

    local function getSlotInfo(character)
        local animal = character:GetAttribute("AnimalName") or currentAnimalName or "Elephant"
        local gender = character:GetAttribute("Gender")     or currentGender or "Female"
        local skin   = character:GetAttribute("Skin")       or currentSkin or "Default"
        return animal, gender, skin
    end

    local function extractMotherName(result)
        if type(result) == "string" and result ~= "" then return result end
        if type(result) ~= "table" then return nil end
        for _, value in ipairs(result) do
            if type(value) == "string" and value ~= "" then return value end
            if type(value) == "table" then
                local name = value.PlayerName or value.Name or value.DisplayName or value.UserName or value.Username
                if type(name) == "string" and name ~= "" then return name end
            end
        end
        for _, value in pairs(result) do
            if type(value) == "string" and value ~= "" then return value end
            if type(value) == "table" then
                local name = value.PlayerName or value.Name or value.DisplayName or value.UserName or value.Username
                if type(name) == "string" and name ~= "" then return name end
            end
        end
        return nil
    end

    local function isBabySavedCharacter(entry)
        if type(entry) ~= "table" then return false end
        local growth = entry.GrowthPercentage
        return type(growth) == "number" and growth <= 0.01
    end

    local function requestBabyMotherName(entry)
        local remote = RS:FindFirstChild("BabySpawnsRequestMotherNamesRemoteFunction")
        if not remote or type(entry) ~= "table" then return nil end
        local animal = entry.AnimalName
        if type(animal) ~= "string" or animal == "" then return nil end
        local requestArg = gameConfig.babySpawnArgs[animal] or animal
        local ok, result = pcall(function() return remote:InvokeServer(requestArg) end)
        if not ok then warn("[GrowthLoop] Baby mother request failed for:", animal) return nil end
        local motherName = extractMotherName(result)
        if motherName then print("[GrowthLoop] Baby mother:", motherName) end
        return motherName
    end

    local function trackCurrentCharacter()
        local character = player.Character
        if not character then return end
        local name = waitForAttribute(character, "CharacterName", 8)
        if name then
            currentGrowthName = name
            shared._currentGrowthName = name
            trackSlotName(name)
            currentAnimalName, currentGender, currentSkin = getSlotInfo(character)
            print("[GrowthLoop] Now tracking:", currentGrowthName, "| Animal:", currentAnimalName, "| Gender:", currentGender)
        else
            warn("[GrowthLoop] Timed out waiting for CharacterName")
        end
    end

    local function spawnAndSetup(slotEntryOrName)
        local syncSavedCharacterRecords      = shared._syncSavedCharacterRecords
        local findSavedCharacterRecordByName = shared._findSavedCharacterRecordByName
        local setSelectedSavedCharacterName  = shared._setSelectedSavedCharacterName

        local entry = slotEntryOrName
        local charName
        if type(slotEntryOrName) == "table" then
            charName = slotEntryOrName.CharacterName
        else
            charName = slotEntryOrName
            if type(findSavedCharacterRecordByName) == "function" then
                local records = type(syncSavedCharacterRecords) == "function" and syncSavedCharacterRecords(true) or nil
                entry = findSavedCharacterRecordByName(charName, records)
            end
        end

        if type(charName) ~= "string" or charName == "" then
            warn("[GrowthLoop] spawnAndSetup called without valid CharacterName")
            return false
        end

        if type(entry) ~= "table" then entry = { CharacterName = charName } end

        if type(setSelectedSavedCharacterName) == "function" then
            setSelectedSavedCharacterName(charName)
        end

        local motherName = isBabySavedCharacter(entry) and requestBabyMotherName(entry) or nil
        local spawnOk, spawnErr = pcall(function()
            if motherName then
                RS.SpawnAsCharacterRemoteFunction:InvokeServer(charName, motherName)
            else
                RS.SpawnAsCharacterRemoteFunction:InvokeServer(charName)
            end
        end)
        if not spawnOk then warn("[GrowthLoop] SpawnAsCharacter failed:", spawnErr) return false end

        local waited = 0
        local spawned = false
        while waited < 10 do
            task.wait(0.2)
            waited = waited + 0.2
            local ch = player.Character
            if ch and ch:FindFirstChild("HumanoidRootPart") then spawned = true break end
        end
        if not spawned then warn("[GrowthLoop] HumanoidRootPart never appeared for:", charName) return false end

        trackSlotName(charName)
        if type(syncSavedCharacterRecords) == "function" then syncSavedCharacterRecords(true) end

        local FOOD_TYPE_BY_ANIMAL = {
            Elephant="Grass", Lion="Meat", Giraffe="Grass", Hippo="Grass",
            Rhino="Grass", Gorilla="Grass", Crocodile="Meat", ["T-Rex"]="Meat",
        }
        local ch = player.Character
        local animal = ch and ch:GetAttribute("AnimalName") or "Elephant"
        local foodType = FOOD_TYPE_BY_ANIMAL[animal] or "Grass"
        pcall(function()
            pcall(function() RS.AnimalGameFrameworkShared.Utils.CanEatDrink.SetFoodTypeRemoteEvent:FireServer(foodType) end)
            pcall(function() RS.VegetationEatingRemoteEvent:FireServer() end)
            print("[GrowthLoop] Set food type:", foodType, "for:", animal)
        end)
        task.wait(0.5)
        pcall(function()
            RS.SaveCharacterStatsRemoteEvent:FireServer(charName, "Oxygen", 100)
            RS.SaveCharacterStatsRemoteEvent:FireServer(charName, "Stamina", 100)
        end)
        return true
    end

    local WAR_SPAWN    = gameConfig.warSpawn
    local GROW_SPAWN   = gameConfig.growSpawn
    local TP_TOLERANCE = 12
    shared._growSpawn  = GROW_SPAWN

    local function confirmedTP(character, targetPos, label, maxAttempts)
        maxAttempts = maxAttempts or 6
        for attempt = 1, maxAttempts do
            local root = character:FindFirstChild("HumanoidRootPart")
            local hum  = character:FindFirstChild("Humanoid")
            if not root or not hum then
                warn("[GrowthLoop] [" .. label .. "] No root/hum on attempt " .. attempt)
                task.wait(1)
            else
                root.Anchored = false
                hum:ChangeState(Enum.HumanoidStateType.Physics)
                for _ = 1, 25 do
                    if character and character:FindFirstChild("HumanoidRootPart") then
                        character:SetPrimaryPartCFrame(CFrame.new(targetPos))
                    end
                    task.wait()
                end
                task.wait(1)
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                for _ = 1, 10 do character:SetAttribute("MovementDisabled", false) task.wait(0.1) end
                local r = character:FindFirstChild("HumanoidRootPart")
                if r then
                    local dist = (r.Position - targetPos).Magnitude
                    print(string.format("[GrowthLoop] [%s] TP attempt %d — dist: %.1f studs", label, attempt, dist))
                    if dist <= TP_TOLERANCE then
                        print("[GrowthLoop] [" .. label .. "] TP confirmed")
                        return true
                    else
                        warn("[GrowthLoop] [" .. label .. "] Too far — retrying")
                    end
                end
            end
        end
        warn("[GrowthLoop] [" .. label .. "] Failed after " .. maxAttempts .. " attempts")
        return false
    end

    local function teleportAndEnable(newChar, charName)
        local charWait = 0
        while charWait < 15 do
            task.wait(0.2)
            charWait = charWait + 0.2
            local ch = player.Character
            if ch and ch:FindFirstChild("HumanoidRootPart") then
                local cname = ch:GetAttribute("CharacterName")
                if cname == charName then newChar = ch break
                elseif charWait >= 5 and cname ~= nil then warn("[GrowthLoop] Name mismatch") newChar = ch break
                elseif charWait >= 8 then warn("[GrowthLoop] CharacterName never loaded") newChar = ch break
                end
            end
        end
        if not newChar then warn("[GrowthLoop] Character never appeared") return end

        task.wait(1.5)
        local ch = player.Character
        if ch then newChar = ch end

        local animal, gender, skin = getSlotInfo(newChar)
        currentAnimalName = animal
        currentGender     = gender
        currentSkin       = skin
        print("[GrowthLoop] Slot info — Animal:", animal, "| Gender:", gender, "| Skin:", skin)

        local expectedAnimal = gameConfig.expectedAnimal
        if expectedAnimal and animal ~= expectedAnimal then
            warn("[GrowthLoop] WARNING: Expected", expectedAnimal, "but got", animal)
        end

        confirmedTP(newChar, GROW_SPAWN, "GrowSpawn")
        print("[GrowthLoop] Waiting 7s for character to settle...")
        task.wait(7)

        local ch2 = player.Character
        local isCarnivore = false
        if ch2 then
            local an = ch2:GetAttribute("AnimalName") or ""
            local CARNIVORES = { Lion=true, Tiger=true, Cheetah=true, Crocodile=true, Leopard=true, ["T-Rex"]=true }
            isCarnivore = CARNIVORES[an] == true
        end

        local function toggleEatDrink(state, label)
            if not isCarnivore then
                if shared._autoEatChecked then shared._autoEatChecked(state) end
            else
                if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(state) end
            end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(state) end
            print("[GrowthLoop] Auto " .. (isCarnivore and "carcass/drink" or "eat/drink") .. " " .. label)
        end

        toggleEatDrink(false, "OFF (pass 1)")
        task.wait(1)
        toggleEatDrink(true,  "ON  (pass 1)")
        task.wait(1)
        toggleEatDrink(false, "OFF (pass 2)")
        task.wait(1)
        toggleEatDrink(true,  "ON  (pass 2) — grow loop active")
    end

    local function teleportToWarSpawn()
        local ch = player.Character
        if not ch then return end
        local root = ch:FindFirstChild("HumanoidRootPart")
        local hum  = ch:FindFirstChild("Humanoid")
        if not root or not hum then return end
        print("[GrowthLoop] 100% grown — teleporting to war spawn")
        confirmedTP(ch, WAR_SPAWN, "WarSpawn")
        print("[GrowthLoop] War spawn TP done")
    end

    local function resetToMenu()
        pcall(function() RS.CustomCharacterResetRemoteFunction:InvokeServer() end)
        task.wait(2)
    end

    local function doGrowthReset()
        withLock(function()
            if shared._autoEatChecked then shared._autoEatChecked(false) end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end
            print("[GrowthLoop] Auto eat/drink OFF — starting growth reset")

            local character = player.Character
            if not character then return end

            local animalName, gender, skin = getSlotInfo(character)
            local newName = getUniqueName(animalName)
            print("[GrowthLoop] Full grown! Creating new slot:", newName, "| Animal:", animalName, "| Gender:", gender)

            teleportToWarSpawn()
            resetToMenu()

            local createOk, createErr = pcall(function()
                RS.CreateNewCharacterRemoteFunction:InvokeServer(newName, animalName, gender, skin)
            end)
            if not createOk then
                warn("[GrowthLoop] CreateNewCharacter failed:", createErr)
                removeName(newName)
                return
            end
            task.wait(2)

            local spawnOk = spawnAndSetup({ CharacterName=newName, AnimalName=animalName, GrowthPercentage=0 })
            if not spawnOk then warn("[GrowthLoop] Spawn failed:", newName) removeName(newName) return end

            teleportAndEnable(nil, newName)

            currentGrowthName = newName
            shared._currentGrowthName = newName
            currentAnimalName = animalName
            currentGender     = gender
            currentSkin       = skin

            local added = trackSlotName(newName)
            print("[GrowthLoop] Now growing:", newName, "| Total slots:", getTrackedSlotTotal(), "| Added:", added)
        end)
    end

    local doExistingSlotCycle
    local doParkOnSlotOne

    doExistingSlotCycle = function()
        withLock(function()
            if shared._autoEatChecked then shared._autoEatChecked(false) end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end
            print("[GrowthLoop] Auto eat/drink OFF — starting slot cycle")

            local getNextExistingSlotRecord = shared._getNextExistingSlotRecord
            local entry, idx, total = type(getNextExistingSlotRecord) == "function"
                and getNextExistingSlotRecord()
                or nil

            if not entry then
                warn("[GrowthLoop] [Existing] No valid slots for", gameConfig.name)
                return
            end

            local slotName = entry.CharacterName
            print("[GrowthLoop] [Existing] Moving to slot", idx, "/", total, ":", slotName, "| Animal:", tostring(entry.AnimalName))

            teleportToWarSpawn()
            resetToMenu()

            local spawnOk = spawnAndSetup(entry)
            if not spawnOk then warn("[GrowthLoop] [Existing] Failed to spawn:", slotName) return end

            task.wait(1)
            local ch = player.Character
            if ch then
                local growth = waitForAttribute(ch, "GrowthPercentage", 8)
                if growth and growth >= 1 then
                    print("[GrowthLoop] [Existing] Slot", slotName, "already 100%, skipping")
                    return
                end
                local animal, gender = getSlotInfo(ch)
                print("[GrowthLoop] [Existing] Slot:", slotName, "| Animal:", animal, "| Gender:", gender)
            end

            teleportAndEnable(nil, slotName)
            currentGrowthName = slotName
            shared._currentGrowthName = slotName
            print("[GrowthLoop] [Existing] Now growing:", slotName)
        end)
    end

    doParkOnSlotOne = function()
        local getFirstExistingSlotRecord = shared._getFirstExistingSlotRecord
        local slotOneEntry = type(getFirstExistingSlotRecord) == "function" and getFirstExistingSlotRecord() or nil
        local slotOne = slotOneEntry and slotOneEntry.CharacterName
        if not slotOne then warn("[GrowthLoop] [Park] No slot 1") return end

        withLock(function()
            local ch = player.Character
            local growth = ch and ch:GetAttribute("GrowthPercentage")
            if growth and growth < 1 then
                print(string.format("[GrowthLoop] [Park] Not full (%.0f%%) — growing existing first", growth * 100))
                setParkingModeState(false)
                growExistingSlots = true
                task.spawn(function() doExistingSlotCycle() end)
                return
            end

            print("[GrowthLoop] [Park] Parking on slot 1:", slotOne)
            if shared._autoEatChecked then shared._autoEatChecked(false) end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end

            resetToMenu()
            task.wait(1)

            local spawnOk = false
            for attempt = 1, 3 do
                spawnOk = spawnAndSetup(slotOneEntry or slotOne)
                if spawnOk then break end
                warn("[GrowthLoop] [Park] Spawn attempt " .. attempt .. " failed")
                task.wait(2)
            end
            if not spawnOk then warn("[GrowthLoop] [Park] All attempts failed") return end

            teleportAndEnable(nil, slotOne)
            currentGrowthName = slotOne
            shared._currentGrowthName = slotOne
            print("[GrowthLoop] [Park] Parked on " .. slotOne)
        end)
    end

    shared._runParkingMode = doParkOnSlotOne

    if pendingParkMode then
        pendingParkMode = false
        task.spawn(function() doParkOnSlotOne() end)
    end

    local function doDeathRecovery()
        if not currentGrowthName then return end
        withLock(function()
            if parkingMode then
                print("[GrowthLoop] Death in parking mode — recovering slot 1")
                task.wait(2)
                task.spawn(doParkOnSlotOne)
                return
            end
            print("[GrowthLoop] Death! Returning to:", currentGrowthName)
            task.wait(2)
            local ok = spawnAndSetup(currentGrowthName)
            if not ok then warn("[GrowthLoop] Death recovery failed for:", currentGrowthName) end
        end)
    end

    task.spawn(trackCurrentCharacter)

    local lastGrowth       = 0
    local growthCheckReady = false

    local function armGrowthCheck(character)
        growthCheckReady = false
        lastGrowth = 0
        task.spawn(function()
            local val = waitForAttribute(character, "GrowthPercentage", 15)
            if val ~= nil then
                lastGrowth = (val >= 1) and 0 or val
                growthCheckReady = true
            else
                warn("[GrowthLoop] GrowthPercentage never appeared")
            end
        end)
    end

    task.spawn(function()
        local ch = player.Character
        if ch then armGrowthCheck(ch) end
    end)

    RunService.Heartbeat:Connect(function()
        if isLooping then return end
        if not growthCheckReady then return end
        if shared._inCarcassEat then return end
        local character = player.Character
        if not character then return end
        local growth = character:GetAttribute("GrowthPercentage")
        if not growth then return end

        if growth >= 0.999 and lastGrowth >= 0.85 then
            local bothOn = growExistingSlots and growNewSlots
            if parkingMode then return end
            if bothOn then
                if not allExistingGrown then
                    slotsGrownThisCycle = slotsGrownThisCycle + 1
                    print("[GrowthLoop] [Smart] Original slot grown:", slotsGrownThisCycle, "/", originalSlotCount)
                    if slotsGrownThisCycle >= originalSlotCount then
                        allExistingGrown = true
                        slotsGrownThisCycle = 0
                        print("[GrowthLoop] [Smart] All original slots grown — creating new")
                    end
                    task.spawn(doExistingSlotCycle)
                elseif getTrackedSlotTotal() < MAX_SLOTS then
                    print("[GrowthLoop] [Smart] Creating new slot (" .. getTrackedSlotTotal() .. "/" .. MAX_SLOTS .. ")")
                    task.spawn(doGrowthReset)
                else
                    setParkingModeState(true)
                    print("[GrowthLoop] [Smart] All 40 slots grown — parking")
                    task.spawn(doParkOnSlotOne)
                end
            elseif growExistingSlots then
                task.spawn(doExistingSlotCycle)
            elseif growNewSlots then
                task.spawn(doGrowthReset)
            end
            return
        end

        local hum = character:FindFirstChild("Humanoid")
        if hum and hum.Health <= 0 and not isLooping then
            lastGrowth = growth
            task.spawn(doDeathRecovery)
            return
        end

        lastGrowth = growth
    end)

    player.CharacterAdded:Connect(function(character)
        lastGrowth = 0
        growthCheckReady = false
        armGrowthCheck(character)
        task.spawn(trackCurrentCharacter)
    end)

local hudGui = Instance.new("ScreenGui")
    hudGui.Name = "GrowthLoopHUD"
    hudGui.ResetOnSpawn = false
    hudGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    hudGui.Parent = game:GetService("CoreGui")

    local CARD_W, CARD_H = 200, 90

    local hudFrame = Instance.new("Frame")
    hudFrame.Size = UDim2.new(0, CARD_W, 0, CARD_H)
    hudFrame.Position = UDim2.new(1, -(CARD_W + 10), 0, 10)
    hudFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
    hudFrame.BackgroundTransparency = 0.08
    hudFrame.BorderSizePixel = 0
    hudFrame.Parent = hudGui
    Instance.new("UICorner", hudFrame).CornerRadius = UDim.new(0, 6)

    local topLine = Instance.new("Frame")
    topLine.Size = UDim2.new(1, 0, 0, 1)
    topLine.Position = UDim2.new(0, 0, 0, 0)
    topLine.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    topLine.BorderSizePixel = 0
    topLine.Parent = hudFrame

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 22)
    header.Position = UDim2.new(0, 0, 0, 0)
    header.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    header.BorderSizePixel = 0
    header.Parent = hudFrame
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 6)

    local headerFix = Instance.new("Frame")
    headerFix.Size = UDim2.new(1, 0, 0, 6)
    headerFix.Position = UDim2.new(0, 0, 1, -6)
    headerFix.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    headerFix.BorderSizePixel = 0
    headerFix.Parent = header

    local headerLabel = Instance.new("TextLabel")
    headerLabel.Size = UDim2.new(1, -10, 1, 0)
    headerLabel.Position = UDim2.new(0, 10, 0, 0)
    headerLabel.BackgroundTransparency = 1
    headerLabel.Text = "growthloop"
    headerLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
    headerLabel.TextSize = 10
    headerLabel.Font = Enum.Font.GothamMedium
    headerLabel.TextXAlignment = Enum.TextXAlignment.Left
    headerLabel.Parent = header

    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 6, 0, 6)
    statusDot.Position = UDim2.new(1, -14, 0.5, -3)
    statusDot.BackgroundColor3 = Color3.fromRGB(80, 210, 100)
    statusDot.BorderSizePixel = 0
    statusDot.Parent = header
    Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

    local function lbl(y, sz, color, bold)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -20, 0, sz + 3)
        l.Position = UDim2.new(0, 10, 0, y)
        l.BackgroundTransparency = 1
        l.TextColor3 = color or Color3.fromRGB(210, 210, 210)
        l.TextSize = sz
        l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.Parent = hudFrame
        return l
    end

    local lblSlot   = lbl(26, 11, Color3.fromRGB(230, 230, 230), true)
    local lblGrowth = lbl(40, 10, Color3.fromRGB(160, 160, 160), false)

    local barBg = Instance.new("Frame")
    barBg.Size = UDim2.new(1, -20, 0, 3)
    barBg.Position = UDim2.new(0, 10, 0, 56)
    barBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    barBg.BorderSizePixel = 0
    barBg.Parent = hudFrame
    Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

    local barFill = Instance.new("Frame")
    barFill.Size = UDim2.new(0, 0, 1, 0)
    barFill.BackgroundColor3 = Color3.fromRGB(80, 210, 100)
    barFill.BorderSizePixel = 0
    barFill.Parent = barBg
    Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

    local lblMode = lbl(62, 9, Color3.fromRGB(100, 100, 100), false)

    local midLine = Instance.new("Frame")
    midLine.Size = UDim2.new(1, -20, 0, 1)
    midLine.Position = UDim2.new(0, 10, 0, 76)
    midLine.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    midLine.BorderSizePixel = 0
    midLine.Parent = hudFrame

    local footer = Instance.new("TextLabel")
    footer.Size = UDim2.new(1, -20, 0, 12)
    footer.Position = UDim2.new(0, 10, 0, 78)
    footer.BackgroundTransparency = 1
    footer.Text = "made by citywraith"
    footer.TextColor3 = Color3.fromRGB(65, 65, 65)
    footer.TextSize = 9
    footer.Font = Enum.Font.Gotham
    footer.TextXAlignment = Enum.TextXAlignment.Left
    footer.Parent = hudFrame

    task.spawn(function()
        while true do
            task.wait(0.5)
            local ch = player.Character
            local growth = ch and ch:GetAttribute("GrowthPercentage") or 0
            local slotName = currentGrowthName or "none"
            local trackedTotal = getTrackedSlotTotal()
            local slotIdx = findSlotIndexByName(currentGrowthName) or 0
            if trackedTotal > 0 then slotIdx = math.clamp(slotIdx, 0, trackedTotal) else slotIdx = 0 end

            lblSlot.Text = string.format("%s  [%d / %d]", slotName, slotIdx, trackedTotal)
            lblGrowth.Text = string.format("growth  %d%%", math.floor(growth * 100))

            local pct = math.clamp(growth, 0, 1)
            local fillColor
            if pct < 0.5 then
                fillColor = Color3.fromRGB(255, math.floor(pct * 2 * 180 + 60), 60)
            else
                fillColor = Color3.fromRGB(math.floor((1 - pct) * 2 * 200 + 55), 210, 60)
            end
            barFill.Size = UDim2.new(pct, 0, 1, 0)
            barFill.BackgroundColor3 = fillColor
            statusDot.BackgroundColor3 = fillColor

            local mode, col
            if parkingMode then
                mode = "passive coins"
                col = Color3.fromRGB(220, 180, 60)
            elseif growExistingSlots and growNewSlots then
                col = Color3.fromRGB(90, 160, 255)
                if allExistingGrown then
                    mode = "smart  >  new slots"
                else
                    mode = string.format("smart  >  existing  %d / %d", slotsGrownThisCycle, originalSlotCount)
                end
            elseif growExistingSlots then
                mode = "growing existing"
                col = Color3.fromRGB(80, 200, 120)
            elseif growNewSlots then
                mode = "growing new"
                col = Color3.fromRGB(255, 140, 70)
            else
                mode = "idle"
                col = Color3.fromRGB(80, 80, 80)
            end

            lblMode.Text = mode
            lblMode.TextColor3 = col
            topLine.BackgroundColor3 = col
        end
    end)

    -- Menu-stuck watchdog
    task.spawn(function()
        local stuckTimer        = 0
        local STUCK_THRESHOLD   = 90
        local parkStuckTimer    = 0
        local PARK_STUCK_THRESHOLD = 90

        while true do
            task.wait(15)
            local ch        = player.Character
            local hasRoot   = ch and ch:FindFirstChild("HumanoidRootPart") ~= nil
            local hasGrowth = ch and ch:GetAttribute("GrowthPercentage") ~= nil

            if parkingMode then
                if not hasRoot or not hasGrowth then
                    parkStuckTimer = parkStuckTimer + 15
                    warn(string.format("[Watchdog] [Park] No character for %ds", parkStuckTimer))
                    if parkStuckTimer >= PARK_STUCK_THRESHOLD then
                        parkStuckTimer = 0
                        if isLooping then forceUnlockGrowthLoop("parking menu watchdog") end
                        task.spawn(doParkOnSlotOne)
                    end
                else
                    parkStuckTimer = 0
                end
                continue
            end

            local anyModeOn = growExistingSlots or growNewSlots
            if not anyModeOn then stuckTimer = 0 continue end

            if not hasRoot or not hasGrowth then
                stuckTimer = stuckTimer + 15
                warn(string.format("[Watchdog] No character for %ds", stuckTimer))
                if stuckTimer >= STUCK_THRESHOLD then
                    stuckTimer = 0
                    if isLooping then forceUnlockGrowthLoop("menu watchdog") end
                    local getFirstExistingSlotRecord = shared._getFirstExistingSlotRecord
                    local fallbackEntry = type(getFirstExistingSlotRecord) == "function" and getFirstExistingSlotRecord() or nil
                    local recoverSlot = currentGrowthName or (fallbackEntry and fallbackEntry.CharacterName)
                    warn("[Watchdog] Recovering:", tostring(recoverSlot))
                    withLock(function()
                        if shared._autoEatChecked then shared._autoEatChecked(false) end
                        if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end
                        local spawnOk = spawnAndSetup(recoverSlot)
                        if not spawnOk then warn("[Watchdog] spawnAndSetup failed") return end
                        task.wait(1)
                        local newCh = player.Character
                        if newCh then
                            local g = waitForAttribute(newCh, "GrowthPercentage", 8)
                            local animal, gender, skin = getSlotInfo(newCh)
                            currentAnimalName = animal currentGender = gender currentSkin = skin
                            if g and g >= 0.999 then
                                print("[Watchdog] Recovered slot already 100%")
                                if growExistingSlots then task.spawn(doExistingSlotCycle)
                                elseif growNewSlots then task.spawn(doGrowthReset) end
                                return
                            end
                            task.wait(1)
                        end
                        teleportAndEnable(nil, recoverSlot)
                        currentGrowthName = recoverSlot
                        shared._currentGrowthName = recoverSlot
                        print("[Watchdog] Recovery complete:", tostring(recoverSlot))
                    end)
                end
            else
                stuckTimer = 0
            end
        end
    end)

    -- Eat/drink reliability watchdog (Lion/Tiger only)
    task.spawn(function()
        local LOW_THRESHOLD = 40
        local RECHECK_WAIT  = 15
        local inCycle       = false

        while true do
            task.wait(5)
            if isLooping or inCycle then continue end
            local ch = player.Character
            if not ch then continue end
            local animalName = ch:GetAttribute("AnimalName") or ""
            if animalName ~= "Lion" and animalName ~= "Tiger" then continue end
            local food  = ch:GetAttribute("Food")
            local water = ch:GetAttribute("Water")
            if not food or not water then continue end
            local carcassOn = shared._autoEatCarcassChecked ~= nil
            local drinkOn   = shared._autoDrinkChecked ~= nil
            if not carcassOn and not drinkOn then continue end

            if food <= LOW_THRESHOLD or water <= LOW_THRESHOLD then
                inCycle = true
                warn(string.format("[EatDrinkWatchdog] [%s] Low — cycling", animalName))
                if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(false) end
                if shared._autoDrinkChecked      then shared._autoDrinkChecked(false)      end
                task.wait(1)
                if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(true)  end
                if shared._autoDrinkChecked      then shared._autoDrinkChecked(true)       end
                print("[EatDrinkWatchdog] Cycled ON — waiting " .. RECHECK_WAIT .. "s")
                task.wait(RECHECK_WAIT)
                local ch2    = player.Character
                local food2  = ch2 and ch2:GetAttribute("Food")
                local water2 = ch2 and ch2:GetAttribute("Water")
                if food2 and water2 then
                    if food2 <= LOW_THRESHOLD or water2 <= LOW_THRESHOLD then
                        warn("[EatDrinkWatchdog] Still low — cycling again")
                        if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(false) end
                        if shared._autoDrinkChecked      then shared._autoDrinkChecked(false)      end
                        task.wait(1)
                        if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(true)  end
                        if shared._autoDrinkChecked      then shared._autoDrinkChecked(true)       end
                    else
                        print(string.format("[EatDrinkWatchdog] Recovered — Food:%.1f Water:%.1f", food2, water2))
                    end
                end
                inCycle = false
            end
        end
    end)

    print("[GrowthLoop] Auto growth loop started.")
end)

-- Safety net
task.spawn(function()
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local player     = Players.LocalPlayer
    local GAME_SAFETY = {
        [18214855317]    = { dangerY=-100, safePos=Vector3.new(-6245.2, 10.0, 4664.3) },
        [6174994284]     = { dangerY=-100, safePos=Vector3.new(-6245.2, 10.0, 4664.3) },
        [9237322219]     = { dangerY=-100, safePos=Vector3.new(1166.835, 24.751, -358.321) },
        [75541741887441] = { dangerY=-100, safePos=Vector3.new(-26.318, 59.041, 190.665) },
    }
    local safeCfg  = GAME_SAFETY[game.GameId] or { dangerY=-100, safePos=Vector3.new(-6245.2, 10.0, 4664.3) }
    local DANGER_Y = safeCfg.dangerY
    local SAFE_POS = safeCfg.safePos
    RunService.Heartbeat:Connect(function()
        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end
        if root.Position.Y < DANGER_Y then
            print("[SafetyNet] Fell through map — teleporting back")
            char:SetPrimaryPartCFrame(CFrame.new(SAFE_POS))
        end
    end)
end)
