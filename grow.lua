
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
                local con = instance:GetPropertyChangedSignal(property):Connect(function(
                )
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

        local stepped = game and game:GetService('RunService').Heartbeat:Connect(function(
            dt
        )
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

            for typeStr in string.gmatch(typeString, '([^|]+)')do
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

            for key, expectedType in pairs(schema)do
                if type(expectedType) ~= 'string' then
                    error("Schema value for key '" .. tostring(key) .. "' must be a string, got " .. type(expectedType), 2)
                end

                local value = data[key]
                local actualType = type(value)
                local expectedTypes = parseTypeString(expectedType)
                local typeMatches = false

                for _, expType in ipairs(expectedTypes)do
                    if actualType == expType then
                        typeMatches = true

                        break
                    end
                end

                if not typeMatches then
                    error("Type mismatch for key '" .. tostring(key) .. "': " .. 'expected ' .. expectedType .. ', got ' .. actualType, 2)
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
            check(props, {
                size = 'number?',
            })

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
                BackgroundColor3 = Color3.fromHSV(0, 0, 0.15),
                BorderColor3 = Color3.new(),
                BorderSizePixel = 0,
                LayoutOrder = 0,
                Size = derive(function()
                    return (mode() == 'vertical' and {verticalSize} or {horizontalSize})[1]
                end),
                create'UIFlexItem'{
                    Name = 'UIFlexItem',
                },
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
                if input.UserInputType ~= MouseMovement then
                    return
                end
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

        local function UpdateFrameDragPosition(
            frame,
            size,
            dragPreviewFrame,
            dragStart,
            startPos,
            input
        )
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

                    if not state then
                        return
                    end

                    for e, k in isOpenedSources do
                        local __DARKLUA_CONTINUE_37 = false

                        repeat
                            if e == i then
                                __DARKLUA_CONTINUE_37 = true

                                break
                            end

                            k(false)

                            __DARKLUA_CONTINUE_37 = true
                        until true

                        if not __DARKLUA_CONTINUE_37 then
                            break
                        end
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
                BackgroundColor3 = Color3.fromHSV(0, 0, 0.1),
                BackgroundTransparency = 0.65,
                ClipsDescendants = true,
                Position = UDim2.fromOffset(20, 20),
                Size = size,
                Visible = true,
                ZIndex = -1,
                create'UICorner'{
                    CornerRadius = UDim.new(0, 8),
                },
            }
            Window = create'Frame'{
                Name = 'Frame1',
                BackgroundColor3 = Color3.fromHSV(0, 0, 0.1),
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
                create'UICorner'{
                    CornerRadius = UDim.new(0, 8),
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
                        BackgroundTransparency = 1,
                        Size = UDim2.new(0, showSidebar and 30 or 0, 1, 0),
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
                    (showSidebar and Separator({
                        mode = source('vertical'),
                    }) or nil),
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
                ['activity-heart'] = Vector2.zero,
                ['airplay'] = Vector2.zero,
                ['airpods'] = Vector2.zero,
                ['alarm-clock'] = Vector2.zero,
                ['alarm-clock-check'] = Vector2.zero,
                ['alarm-clock-minus'] = Vector2.zero,
                ['alarm-clock-off'] = Vector2.zero,
                ['alarm-clock-plus'] = Vector2.zero,
                ['alert-circle'] = Vector2.zero,
                ['alert-hexagon'] = Vector2.zero,
                ['alert-octagon'] = Vector2.zero,
                ['alert-square'] = Vector2.zero,
                ['alert-triangle'] = Vector2.zero,
                ['align-bottom'] = Vector2.zero,
                ['align-bottom-02'] = Vector2.zero,
                ['align-center'] = Vector2.zero,
                ['align-horizontal-centre'] = Vector2.zero,
                ['align-horizontal-centre-02'] = Vector2.zero,
                ['align-justify'] = Vector2.zero,
                ['align-left'] = Vector2.zero,
                ['align-left-02'] = Vector2.zero,
                ['align-right'] = Vector2.zero,
                ['align-right-02'] = Vector2.zero,
                ['align-top'] = Vector2.zero,
                ['align-top-02'] = Vector2.zero,
                ['align-vertical-center'] = Vector2.zero,
                ['align-vertical-center-02'] = Vector2.zero,
                ['anchor'] = Vector2.zero,
                ['annotation'] = Vector2.zero,
                ['annotation-alert'] = Vector2.zero,
                ['annotation-check'] = Vector2.zero,
                ['annotation-dots'] = Vector2.zero,
                ['annotation-heart'] = Vector2.zero,
                ['annotation-info'] = Vector2.zero,
                ['annotation-plus'] = Vector2.zero,
                ['annotation-question'] = Vector2.zero,
                ['annotation-x'] = Vector2.zero,
                ['announcement'] = Vector2.zero,
                ['announcement-02'] = Vector2.zero,
                ['announcement-03'] = Vector2.zero,
                ['archive'] = Vector2.zero,
                ['arrow-block-down'] = Vector2.zero,
                ['arrow-block-left'] = Vector2.zero,
                ['arrow-block-right'] = Vector2.zero,
                ['arrow-block-up'] = Vector2.zero,
                ['arrow-circle-broken-down'] = Vector2.zero,
                ['arrow-circle-broken-down-left'] = Vector2.zero,
                ['arrow-circle-broken-down-right'] = Vector2.zero,
                ['arrow-circle-broken-left'] = Vector2.zero,
                ['arrow-circle-broken-right'] = Vector2.zero,
                ['arrow-circle-broken-up'] = Vector2.zero,
                ['arrow-circle-broken-up-left'] = Vector2.zero,
                ['arrow-circle-broken-up-right'] = Vector2.zero,
                ['arrow-circle-down'] = Vector2.zero,
                ['arrow-circle-down-left'] = Vector2.zero,
                ['arrow-circle-down-right'] = Vector2.zero,
                ['arrow-circle-left'] = Vector2.zero,
                ['arrow-circle-right'] = Vector2.zero,
                ['arrow-circle-up'] = Vector2.zero,
                ['arrow-circle-up-left'] = Vector2.zero,
                ['arrow-circle-up-right'] = Vector2.zero,
                ['arrow-down'] = Vector2.zero,
                ['arrow-down-left'] = Vector2.zero,
                ['arrow-down-right'] = Vector2.zero,
                ['arrow-left'] = Vector2.zero,
                ['arrow-narrow-down'] = Vector2.zero,
                ['arrow-narrow-down-left'] = Vector2.zero,
                ['arrow-narrow-down-right'] = Vector2.zero,
                ['arrow-narrow-left'] = Vector2.zero,
                ['arrow-narrow-right'] = Vector2.zero,
                ['arrow-narrow-up'] = Vector2.zero,
                ['arrow-narrow-up-left'] = Vector2.zero,
                ['arrow-narrow-up-right'] = Vector2.zero,
                ['arrow-right'] = Vector2.zero,
                ['arrow-square-down'] = Vector2.zero,
                ['arrow-square-down-left'] = Vector2.zero,
                ['arrow-square-down-right'] = Vector2.zero,
                ['arrow-square-left'] = Vector2.zero,
                ['arrow-square-right'] = Vector2.zero,
                ['arrow-square-up'] = Vector2.zero,
                ['arrow-square-up-left'] = Vector2.zero,
                ['arrow-square-up-right'] = Vector2.zero,
                ['arrow-up'] = Vector2.zero,
                ['arrow-up-left'] = Vector2.zero,
                ['arrow-up-right'] = Vector2.zero,
                ['arrows-down'] = Vector2.zero,
                ['arrows-left'] = Vector2.zero,
                ['arrows-right'] = Vector2.zero,
                ['arrows-triangle'] = Vector2.zero,
                ['arrows-up'] = Vector2.zero,
                ['asterisk-01'] = Vector2.zero,
                ['asterisk-02'] = Vector2.zero,
                ['at-sign'] = Vector2.zero,
                ['atom'] = Vector2.zero,
                ['atom-02'] = Vector2.zero,
                ['attachment'] = Vector2.zero,
                ['attachment-02'] = Vector2.zero,
                ['award'] = Vector2.zero,
                ['award-02'] = Vector2.zero,
                ['award-03'] = Vector2.zero,
                ['award-04'] = Vector2.zero,
                ['award-05'] = Vector2.zero,
                ['backpack'] = Vector2.zero,
                ['bank'] = Vector2.zero,
                ['bank-note'] = Vector2.zero,
                ['bank-note-02'] = Vector2.zero,
                ['bank-note-03'] = Vector2.zero,
                ['bar-chart'] = Vector2.zero,
                ['bar-chart-02'] = Vector2.zero,
                ['bar-chart-03'] = Vector2.zero,
                ['bar-chart-04'] = Vector2.zero,
                ['bar-chart-05'] = Vector2.zero,
                ['bar-chart-06'] = Vector2.zero,
                ['bar-chart-07'] = Vector2.zero,
                ['bar-chart-08'] = Vector2.zero,
                ['bar-chart-09'] = Vector2.zero,
                ['bar-chart-10'] = Vector2.zero,
                ['bar-chart-11'] = Vector2.zero,
                ['bar-chart-12'] = Vector2.zero,
                ['bar-chart-circle'] = Vector2.zero,
                ['bar-chart-circle-02'] = Vector2.zero,
                ['bar-chart-circle-03'] = Vector2.zero,
                ['bar-chart-growdown'] = Vector2.zero,
                ['bar-chart-growup'] = Vector2.zero,
                ['bar-chart-square'] = Vector2.zero,
                ['bar-chart-square-02'] = Vector2.zero,
                ['bar-chart-square-03'] = Vector2.zero,
                ['bar-chart-square-down'] = Vector2.zero,
                ['bar-chart-square-minus'] = Vector2.zero,
                ['bar-chart-square-plus'] = Vector2.zero,
                ['bar-chart-square-up'] = Vector2.zero,
                ['bar-line-chart'] = Vector2.zero,
                ['battery-charging'] = Vector2.zero,
                ['battery-charging-02'] = Vector2.zero,
                ['battery-empty'] = Vector2.zero,
                ['battery-full'] = Vector2.zero,
                ['battery-low'] = Vector2.zero,
                ['battery-mid'] = Vector2.zero,
                ['beaker'] = Vector2.zero,
                ['beaker-02'] = Vector2.zero,
                ['bell'] = Vector2.zero,
                ['bell-02'] = Vector2.zero,
                ['bell-03'] = Vector2.zero,
                ['bell-04'] = Vector2.zero,
                ['bell-minus'] = Vector2.zero,
                ['bell-off'] = Vector2.zero,
                ['bell-off-02'] = Vector2.zero,
                ['bell-off-03'] = Vector2.zero,
                ['bell-plus'] = Vector2.zero,
                ['bell-ringing'] = Vector2.zero,
                ['bell-ringing-02'] = Vector2.zero,
                ['bell-ringing-03'] = Vector2.zero,
                ['bell-ringing-04'] = Vector2.zero,
                ['bezier-curve'] = Vector2.zero,
                ['bezier-curve-02'] = Vector2.zero,
                ['bezier-curve-03'] = Vector2.zero,
                ['bluetooth-connect'] = Vector2.zero,
                ['bluetooth-off'] = Vector2.zero,
                ['bluetooth-on'] = Vector2.zero,
                ['bluetooth-signal'] = Vector2.zero,
                ['bold'] = Vector2.zero,
                ['bold-02'] = Vector2.zero,
                ['bold-square'] = Vector2.zero,
                ['book-closed'] = Vector2.zero,
                ['book-open'] = Vector2.zero,
                ['book-open-02'] = Vector2.zero,
                ['bookmark'] = Vector2.zero,
                ['bookmark-add'] = Vector2.zero,
                ['bookmark-check'] = Vector2.zero,
                ['bookmark-minus'] = Vector2.zero,
                ['bookmark-x'] = Vector2.zero,
                ['box'] = Vector2.zero,
                ['brackets'] = Vector2.zero,
                ['brackets-check'] = Vector2.zero,
                ['brackets-ellipses'] = Vector2.zero,
                ['brackets-minus'] = Vector2.zero,
                ['brackets-plus'] = Vector2.zero,
                ['brackets-slash'] = Vector2.zero,
                ['brackets-x'] = Vector2.zero,
                ['briefcase'] = Vector2.zero,
                ['briefcase-02'] = Vector2.zero,
                ['browser'] = Vector2.zero,
                ['brush'] = Vector2.zero,
                ['brush-02'] = Vector2.zero,
                ['brush-03'] = Vector2.zero,
                ['building'] = Vector2.zero,
                ['building-02'] = Vector2.zero,
                ['building-03'] = Vector2.zero,
                ['building-04'] = Vector2.zero,
                ['building-05'] = Vector2.zero,
                ['building-06'] = Vector2.zero,
                ['building-07'] = Vector2.zero,
                ['building-08'] = Vector2.zero,
                ['bus'] = Vector2.zero,
                ['calculator'] = Vector2.zero,
                ['calendar'] = Vector2.zero,
                ['calendar-check'] = Vector2.zero,
                ['calendar-check-02'] = Vector2.zero,
                ['calendar-date'] = Vector2.zero,
                ['calendar-heart'] = Vector2.zero,
                ['calendar-heart-02'] = Vector2.zero,
                ['calendar-minus'] = Vector2.zero,
                ['calendar-minus-02'] = Vector2.zero,
                ['calendar-plus'] = Vector2.zero,
                ['calendar-plus-02'] = Vector2.zero,
                ['camera'] = Vector2.zero,
                ['camera-02'] = Vector2.zero,
                ['camera-03'] = Vector2.zero,
                ['camera-lens'] = Vector2.zero,
                ['camera-off'] = Vector2.zero,
                ['camera-plus'] = Vector2.zero,
                ['car'] = Vector2.zero,
                ['car-02'] = Vector2.zero,
                ['certificate'] = Vector2.zero,
                ['certificate-02'] = Vector2.zero,
                ['chart-breakout-circle'] = Vector2.zero,
                ['chart-breakout-square'] = Vector2.zero,
                ['check'] = Vector2.zero,
                ['check-circle'] = Vector2.zero,
                ['check-circle-broken'] = Vector2.zero,
                ['check-done'] = Vector2.zero,
                ['check-done-02'] = Vector2.zero,
                ['check-heart'] = Vector2.zero,
                ['check-square'] = Vector2.zero,
                ['check-square-broken'] = Vector2.zero,
                ['check-verified'] = Vector2.zero,
                ['check-verified-02'] = Vector2.zero,
                ['check-verified-03'] = Vector2.zero,
                ['chevron-down'] = Vector2.zero,
                ['chevron-down-double'] = Vector2.zero,
                ['chevron-left'] = Vector2.zero,
                ['chevron-left-double'] = Vector2.zero,
                ['chevron-right'] = Vector2.zero,
                ['chevron-right-double'] = Vector2.zero,
                ['chevron-selector-horizontal'] = Vector2.zero,
                ['chevron-selector-vertical'] = Vector2.zero,
                ['chevron-up'] = Vector2.zero,
                ['chevron-up-double'] = Vector2.zero,
                ['chrome-cast'] = Vector2.zero,
                ['circle'] = Vector2.zero,
                ['circle-cut'] = Vector2.zero,
                ['clapperboard'] = Vector2.zero,
                ['clipboard'] = Vector2.zero,
                ['clipboard-attachment'] = Vector2.zero,
                ['clipboard-check'] = Vector2.zero,
                ['clipboard-download'] = Vector2.zero,
                ['clipboard-minus'] = Vector2.zero,
                ['clipboard-plus'] = Vector2.zero,
                ['clipboard-x'] = Vector2.zero,
                ['clock'] = Vector2.zero,
                ['clock-check'] = Vector2.zero,
                ['clock-fast-forward'] = Vector2.zero,
                ['clock-plus'] = Vector2.zero,
                ['clock-refresh'] = Vector2.zero,
                ['clock-rewind'] = Vector2.zero,
                ['clock-snooze'] = Vector2.zero,
                ['clock-stopwatch'] = Vector2.zero,
                ['cloud'] = Vector2.zero,
                ['cloud-02'] = Vector2.zero,
                ['cloud-03'] = Vector2.zero,
                ['cloud-blank'] = Vector2.zero,
                ['cloud-blank-02'] = Vector2.zero,
                ['cloud-lightning'] = Vector2.zero,
                ['cloud-moon'] = Vector2.zero,
                ['cloud-off'] = Vector2.zero,
                ['cloud-raining'] = Vector2.zero,
                ['cloud-raining-02'] = Vector2.zero,
                ['cloud-raining-03'] = Vector2.zero,
                ['cloud-raining-04'] = Vector2.zero,
                ['cloud-raining-05'] = Vector2.zero,
                ['cloud-raining-06'] = Vector2.zero,
                ['cloud-snowing'] = Vector2.zero,
                ['cloud-snowing-02'] = Vector2.zero,
                ['cloud-sun'] = Vector2.zero,
                ['cloud-sun-02'] = Vector2.zero,
                ['cloud-sun-03'] = Vector2.zero,
                ['code'] = Vector2.zero,
                ['code-02'] = Vector2.zero,
                ['code-browser'] = Vector2.zero,
                ['code-circle'] = Vector2.zero,
                ['code-circle-02'] = Vector2.zero,
                ['code-circle-03'] = Vector2.zero,
                ['code-snippet'] = Vector2.zero,
                ['code-snippet-02'] = Vector2.zero,
                ['code-square'] = Vector2.zero,
                ['code-square-02'] = Vector2.zero,
                ['codepen'] = Vector2.zero,
                ['coins'] = Vector2.zero,
                ['coins-02'] = Vector2.zero,
                ['coins-03'] = Vector2.zero,
                ['coins-04'] = Vector2.zero,
                ['coins-hand'] = Vector2.zero,
                ['coins-stacked'] = Vector2.zero,
                ['coins-stacked-02'] = Vector2.zero,
                ['coins-stacked-03'] = Vector2.zero,
                ['coins-stacked-04'] = Vector2.zero,
                ['coins-swap'] = Vector2.zero,
                ['coins-swap-02'] = Vector2.zero,
                ['colors'] = Vector2.zero,
                ['columns'] = Vector2.zero,
                ['columns-02'] = Vector2.zero,
                ['columns-03'] = Vector2.zero,
                ['command'] = Vector2.zero,
                ['compass'] = Vector2.zero,
                ['compass-02'] = Vector2.zero,
                ['compass-03'] = Vector2.zero,
                ['container'] = Vector2.zero,
                ['contrast'] = Vector2.zero,
                ['contrast-02'] = Vector2.zero,
                ['contrast-03'] = Vector2.zero,
                ['copy'] = Vector2.zero,
                ['copy-02'] = Vector2.zero,
                ['copy-03'] = Vector2.zero,
                ['copy-04'] = Vector2.zero,
                ['copy-05'] = Vector2.zero,
                ['copy-06'] = Vector2.zero,
                ['copy-07'] = Vector2.zero,
                ['copy-dashed'] = Vector2.zero,
                ['corner-down-left'] = Vector2.zero,
                ['corner-down-right'] = Vector2.zero,
                ['corner-left-down'] = Vector2.zero,
                ['corner-left-up'] = Vector2.zero,
                ['corner-right-down'] = Vector2.zero,
                ['corner-right-up'] = Vector2.zero,
                ['corner-up-left'] = Vector2.zero,
                ['corner-up-right'] = Vector2.zero,
                ['cpu-chip'] = Vector2.zero,
                ['cpu-chip-02'] = Vector2.zero,
                ['credit-card'] = Vector2.zero,
                ['credit-card-02'] = Vector2.zero,
                ['credit-card-check'] = Vector2.zero,
                ['credit-card-down'] = Vector2.zero,
                ['credit-card-download'] = Vector2.zero,
                ['credit-card-edit'] = Vector2.zero,
                ['credit-card-lock'] = Vector2.zero,
                ['credit-card-minus'] = Vector2.zero,
                ['credit-card-plus'] = Vector2.zero,
                ['credit-card-refresh'] = Vector2.zero,
                ['credit-card-search'] = Vector2.zero,
                ['credit-card-shield'] = Vector2.zero,
                ['credit-card-up'] = Vector2.zero,
                ['credit-card-upload'] = Vector2.zero,
                ['credit-card-x'] = Vector2.zero,
                ['crop'] = Vector2.zero,
                ['crop-02'] = Vector2.zero,
                ['cryptocurrency'] = Vector2.zero,
                ['cryptocurrency-02'] = Vector2.zero,
                ['cryptocurrency-03'] = Vector2.zero,
                ['cryptocurrency-04'] = Vector2.zero,
                ['cube'] = Vector2.zero,
                ['cube-02'] = Vector2.zero,
                ['cube-03'] = Vector2.zero,
                ['cube-04'] = Vector2.zero,
                ['cube-outline'] = Vector2.zero,
                ['currency-bitcoin'] = Vector2.zero,
                ['currency-bitcoin-circle'] = Vector2.zero,
                ['currency-dollar'] = Vector2.zero,
                ['currency-dollar-circle'] = Vector2.zero,
                ['currency-ethereum'] = Vector2.zero,
                ['currency-ethereum-circle'] = Vector2.zero,
                ['currency-euro'] = Vector2.zero,
                ['currency-euro-circle'] = Vector2.zero,
                ['currency-pound'] = Vector2.zero,
                ['currency-pound-circle'] = Vector2.zero,
                ['currency-ruble'] = Vector2.zero,
                ['currency-ruble-circle'] = Vector2.zero,
                ['currency-rupee'] = Vector2.zero,
                ['currency-rupee-circle'] = Vector2.zero,
                ['currency-yen'] = Vector2.zero,
                ['currency-yen-circle'] = Vector2.zero,
                ['cursor'] = Vector2.zero,
                ['cursor-02'] = Vector2.zero,
                ['cursor-03'] = Vector2.zero,
                ['cursor-04'] = Vector2.zero,
                ['cursor-box'] = Vector2.zero,
                ['cursor-click'] = Vector2.zero,
                ['cursor-click-02'] = Vector2.zero,
                ['data'] = Vector2.zero,
                ['database'] = Vector2.zero,
                ['database-02'] = Vector2.zero,
                ['database-03'] = Vector2.zero,
                ['dataflow'] = Vector2.zero,
                ['dataflow-02'] = Vector2.zero,
                ['dataflow-03'] = Vector2.zero,
                ['dataflow-04'] = Vector2.zero,
                ['delete'] = Vector2.zero,
                ['diamond'] = Vector2.zero,
                ['diamond-02'] = Vector2.zero,
                ['dice'] = Vector2.zero,
                ['dice-2'] = Vector2.zero,
                ['dice-3'] = Vector2.zero,
                ['dice-4'] = Vector2.zero,
                ['dice-5'] = Vector2.zero,
                ['dice-6'] = Vector2.zero,
                ['disc'] = Vector2.zero,
                ['disc-02'] = Vector2.zero,
                ['distribute-spacing-horizontal'] = Vector2.zero,
                ['distribute-spacing-vertical'] = Vector2.zero,
                ['divide'] = Vector2.zero,
                ['divide-02'] = Vector2.zero,
                ['divide-03'] = Vector2.zero,
                ['divide-circle'] = Vector2.zero,
                ['divider'] = Vector2.zero,
                ['dotpoints'] = Vector2.zero,
                ['dotpoints-02'] = Vector2.zero,
                ['dots-grid'] = Vector2.zero,
                ['dots-horizontal'] = Vector2.zero,
                ['dots-vertical'] = Vector2.zero,
                ['download'] = Vector2.zero,
                ['download-02'] = Vector2.zero,
                ['download-03'] = Vector2.zero,
                ['download-04'] = Vector2.zero,
                ['download-circle'] = Vector2.zero,
                ['download-cloud-01'] = Vector2.zero,
                ['download-cloud-02'] = Vector2.zero,
                ['download-line'] = Vector2.zero,
                ['drop'] = Vector2.zero,
                ['droplets'] = Vector2.zero,
                ['droplets-02'] = Vector2.zero,
                ['droplets-03'] = Vector2.zero,
                ['dropper'] = Vector2.zero,
                ['edit-01'] = Vector2.zero,
                ['edit-02'] = Vector2.zero,
                ['edit-03'] = Vector2.zero,
                ['edit-04'] = Vector2.zero,
                ['edit-05'] = Vector2.zero,
                ['equal'] = Vector2.zero,
                ['equal-not'] = Vector2.zero,
                ['eraser'] = Vector2.zero,
                ['expand'] = Vector2.zero,
                ['expand-02'] = Vector2.zero,
                ['expand-03'] = Vector2.zero,
                ['expand-04'] = Vector2.zero,
                ['expand-05'] = Vector2.zero,
                ['expand-06'] = Vector2.zero,
                ['expand-lg'] = Vector2.zero,
                ['eye'] = Vector2.zero,
                ['eye-off'] = Vector2.zero,
                ['face-content'] = Vector2.zero,
                ['face-frown'] = Vector2.zero,
                ['face-happy'] = Vector2.zero,
                ['face-id'] = Vector2.zero,
                ['face-id-square'] = Vector2.zero,
                ['face-neutral'] = Vector2.zero,
                ['face-sad'] = Vector2.zero,
                ['face-smile'] = Vector2.zero,
                ['face-wink'] = Vector2.zero,
                ['fast-backward'] = Vector2.zero,
                ['fast-forward'] = Vector2.zero,
                ['feather'] = Vector2.zero,
                ['figma'] = Vector2.zero,
                ['file'] = Vector2.zero,
                ['file-02'] = Vector2.zero,
                ['file-03'] = Vector2.zero,
                ['file-04'] = Vector2.zero,
                ['file-05'] = Vector2.zero,
                ['file-06'] = Vector2.zero,
                ['file-07'] = Vector2.zero,
                ['file-attachment'] = Vector2.zero,
                ['file-attachment-02'] = Vector2.zero,
                ['file-attachment-03'] = Vector2.zero,
                ['file-attachment-04'] = Vector2.zero,
                ['file-attachment-05'] = Vector2.zero,
                ['file-check'] = Vector2.zero,
                ['file-check-02'] = Vector2.zero,
                ['file-check-03'] = Vector2.zero,
                ['file-code'] = Vector2.zero,
                ['file-code-02'] = Vector2.zero,
                ['file-download'] = Vector2.zero,
                ['file-download-02'] = Vector2.zero,
                ['file-download-03'] = Vector2.zero,
                ['file-heart'] = Vector2.zero,
                ['file-heart-02'] = Vector2.zero,
                ['file-heart-03'] = Vector2.zero,
                ['file-lock'] = Vector2.zero,
                ['file-lock-02'] = Vector2.zero,
                ['file-lock-03'] = Vector2.zero,
                ['file-minus'] = Vector2.zero,
                ['file-minus-02'] = Vector2.zero,
                ['file-minus-03'] = Vector2.zero,
                ['file-plus'] = Vector2.zero,
                ['file-plus-02'] = Vector2.zero,
                ['file-plus-03'] = Vector2.zero,
                ['file-question'] = Vector2.zero,
                ['file-question-02'] = Vector2.zero,
                ['file-question-03'] = Vector2.zero,
                ['file-search'] = Vector2.zero,
                ['file-search-02'] = Vector2.zero,
                ['file-search-03'] = Vector2.zero,
                ['file-shield'] = Vector2.zero,
                ['file-shield-02'] = Vector2.zero,
                ['file-shield-03'] = Vector2.zero,
                ['file-x'] = Vector2.zero,
                ['file-x-02'] = Vector2.zero,
                ['file-x-03'] = Vector2.zero,
                ['film'] = Vector2.zero,
                ['film-02'] = Vector2.zero,
                ['film-03'] = Vector2.zero,
                ['filter-funnel'] = Vector2.zero,
                ['filter-funnel-02'] = Vector2.zero,
                ['filter-lines'] = Vector2.zero,
                ['fingerprint'] = Vector2.zero,
                ['fingerprint-02'] = Vector2.zero,
                ['fingerprint-03'] = Vector2.zero,
                ['fingerprint-04'] = Vector2.zero,
                ['flag'] = Vector2.zero,
                ['flag-02'] = Vector2.zero,
                ['flag-03'] = Vector2.zero,
                ['flag-04'] = Vector2.zero,
                ['flag-05'] = Vector2.zero,
                ['flag-06'] = Vector2.zero,
                ['flash'] = Vector2.zero,
                ['flash-off'] = Vector2.zero,
                ['flex-align-bottom'] = Vector2.zero,
                ['flex-align-left'] = Vector2.zero,
                ['flex-align-right'] = Vector2.zero,
                ['flex-align-top'] = Vector2.zero,
                ['flip-backward'] = Vector2.zero,
                ['flip-forward'] = Vector2.zero,
                ['folder'] = Vector2.zero,
                ['folder-check'] = Vector2.zero,
                ['folder-closed'] = Vector2.zero,
                ['folder-code'] = Vector2.zero,
                ['folder-download'] = Vector2.zero,
                ['folder-lock'] = Vector2.zero,
                ['folder-minus'] = Vector2.zero,
                ['folder-plus'] = Vector2.zero,
                ['folder-question'] = Vector2.zero,
                ['folder-search'] = Vector2.zero,
                ['folder-shield'] = Vector2.zero,
                ['folder-x'] = Vector2.zero,
                ['framer'] = Vector2.zero,
                ['gaming-pad'] = Vector2.zero,
                ['gaming-pad-02'] = Vector2.zero,
                ['gift'] = Vector2.zero,
                ['gift-02'] = Vector2.zero,
                ['git-branch'] = Vector2.zero,
                ['git-branch-02'] = Vector2.zero,
                ['git-commit'] = Vector2.zero,
                ['git-merge'] = Vector2.zero,
                ['git-pull-request'] = Vector2.zero,
                ['glasses'] = Vector2.zero,
                ['glasses-02'] = Vector2.zero,
                ['globe'] = Vector2.zero,
                ['globe-02'] = Vector2.zero,
                ['globe-03'] = Vector2.zero,
                ['globe-04'] = Vector2.zero,
                ['globe-05'] = Vector2.zero,
                ['globe-06'] = Vector2.zero,
                ['globe-slated'] = Vector2.zero,
                ['globe-slated-02'] = Vector2.zero,
                ['google-chrome'] = Vector2.zero,
                ['graduation-hat'] = Vector2.zero,
                ['graduation-hat-02'] = Vector2.zero,
                ['grid'] = Vector2.zero,
                ['grid-02'] = Vector2.zero,
                ['grid-03'] = Vector2.zero,
                ['grid-dots-blank'] = Vector2.zero,
                ['grid-dots-bottom'] = Vector2.zero,
                ['grid-dots-horizontal-center'] = Vector2.zero,
                ['grid-dots-left'] = Vector2.zero,
                ['grid-dots-outer'] = Vector2.zero,
                ['grid-dots-right'] = Vector2.zero,
                ['grid-dots-top'] = Vector2.zero,
                ['grid-dots-vertical-center'] = Vector2.zero,
                ['hand'] = Vector2.zero,
                ['hard-drive'] = Vector2.zero,
                ['hash'] = Vector2.zero,
                ['hash-02'] = Vector2.zero,
                ['hash-italic'] = Vector2.zero,
                ['heading'] = Vector2.zero,
                ['heading-02'] = Vector2.zero,
                ['heading-square'] = Vector2.zero,
                ['headphones'] = Vector2.zero,
                ['headphones-02'] = Vector2.zero,
                ['heart'] = Vector2.zero,
                ['heart-circle'] = Vector2.zero,
                ['heart-hand'] = Vector2.zero,
                ['heart-hexagon'] = Vector2.zero,
                ['heart-octagon'] = Vector2.zero,
                ['heart-rounded'] = Vector2.zero,
                ['heart-square'] = Vector2.zero,
                ['hearts'] = Vector2.zero,
                ['help-circle'] = Vector2.zero,
                ['help-hexagon'] = Vector2.zero,
                ['help-octagon'] = Vector2.zero,
                ['help-square'] = Vector2.zero,
                ['hexagon'] = Vector2.zero,
                ['hexagon-02'] = Vector2.zero,
                ['home'] = Vector2.zero,
                ['home-02'] = Vector2.zero,
                ['home-03'] = Vector2.zero,
                ['home-04'] = Vector2.zero,
                ['home-05'] = Vector2.zero,
                ['home-line'] = Vector2.zero,
                ['home-smile'] = Vector2.zero,
                ['horizontal-bar-chart'] = Vector2.zero,
                ['horizontal-bar-chart-02'] = Vector2.zero,
                ['horizontal-bar-chart-03'] = Vector2.zero,
                ['hourglass'] = Vector2.zero,
                ['hourglass-02'] = Vector2.zero,
                ['hourglass-03'] = Vector2.zero,
                ['hurricane'] = Vector2.zero,
                ['hurricane-02'] = Vector2.zero,
                ['hurricane-03'] = Vector2.zero,
                ['image'] = Vector2.zero,
                ['image-02'] = Vector2.zero,
                ['image-03'] = Vector2.zero,
                ['image-04'] = Vector2.zero,
                ['image-05'] = Vector2.zero,
                ['image-check'] = Vector2.zero,
                ['image-circle'] = Vector2.zero,
                ['image-down'] = Vector2.zero,
                ['image-indent-left'] = Vector2.zero,
                ['image-indent-right'] = Vector2.zero,
                ['image-left'] = Vector2.zero,
                ['image-plus'] = Vector2.zero,
                ['image-right'] = Vector2.zero,
                ['image-up'] = Vector2.zero,
                ['image-user'] = Vector2.zero,
                ['image-user-check'] = Vector2.zero,
                ['image-user-down'] = Vector2.zero,
                ['image-user-left'] = Vector2.zero,
                ['image-user-plus'] = Vector2.zero,
                ['image-user-right'] = Vector2.zero,
                ['image-user-up'] = Vector2.zero,
                ['image-user-x'] = Vector2.zero,
                ['image-x'] = Vector2.zero,
                ['inbox'] = Vector2.zero,
                ['inbox-02'] = Vector2.zero,
                ['infinity'] = Vector2.zero,
                ['info-circle'] = Vector2.zero,
                ['info-hexagon'] = Vector2.zero,
                ['info-octagon'] = Vector2.zero,
                ['info-square'] = Vector2.zero,
                ['intersect-circle'] = Vector2.zero,
                ['intersect-square'] = Vector2.zero,
                ['iphone'] = Vector2.zero,
                ['italic'] = Vector2.zero,
                ['italic-02'] = Vector2.zero,
                ['italic-square'] = Vector2.zero,
                ['key'] = Vector2.zero,
                ['key-02'] = Vector2.zero,
                ['keyboard'] = Vector2.zero,
                ['keyboard-02'] = Vector2.zero,
                ['laptop'] = Vector2.zero,
                ['laptop-02'] = Vector2.zero,
                ['layer-single'] = Vector2.zero,
                ['layers-three'] = Vector2.zero,
                ['layers-three-02'] = Vector2.zero,
                ['layers-two'] = Vector2.zero,
                ['layers-two-02'] = Vector2.zero,
                ['layout-alt'] = Vector2.zero,
                ['layout-alt-02'] = Vector2.zero,
                ['layout-alt-03'] = Vector2.zero,
                ['layout-alt-04'] = Vector2.zero,
                ['layout-bottom'] = Vector2.zero,
                ['layout-grid'] = Vector2.zero,
                ['layout-grid-02'] = Vector2.zero,
                ['layout-left'] = Vector2.zero,
                ['layout-right'] = Vector2.zero,
                ['layout-top'] = Vector2.zero,
                ['left-indent'] = Vector2.zero,
                ['left-indent-02'] = Vector2.zero,
                ['letter-spacing'] = Vector2.zero,
                ['letter-spacing-02'] = Vector2.zero,
                ['life-buoy'] = Vector2.zero,
                ['life-buoy-02'] = Vector2.zero,
                ['lightbulb'] = Vector2.zero,
                ['lightbulb-02'] = Vector2.zero,
                ['lightbulb-03'] = Vector2.zero,
                ['lightbulb-04'] = Vector2.zero,
                ['lightbulb-05'] = Vector2.zero,
                ['lightning'] = Vector2.zero,
                ['lightning-02'] = Vector2.zero,
                ['line-chart-down'] = Vector2.zero,
                ['line-chart-down-02'] = Vector2.zero,
                ['line-chart-down-03'] = Vector2.zero,
                ['line-chart-down-04'] = Vector2.zero,
                ['line-chart-down-05'] = Vector2.zero,
                ['line-chart-up'] = Vector2.zero,
                ['line-chart-up-02'] = Vector2.zero,
                ['line-chart-up-03'] = Vector2.zero,
                ['line-chart-up-04'] = Vector2.zero,
                ['line-chart-up-05'] = Vector2.zero,
                ['line-height'] = Vector2.zero,
                ['link'] = Vector2.zero,
                ['link-02'] = Vector2.zero,
                ['link-03'] = Vector2.zero,
                ['link-04'] = Vector2.zero,
                ['link-05'] = Vector2.zero,
                ['link-broken'] = Vector2.zero,
                ['link-broken-02'] = Vector2.zero,
                ['link-external-01'] = Vector2.zero,
                ['link-external-02'] = Vector2.zero,
                ['list'] = Vector2.zero,
                ['loading-01'] = Vector2.zero,
                ['loading-02'] = Vector2.zero,
                ['loading-03'] = Vector2.zero,
                ['lock'] = Vector2.zero,
                ['lock-02'] = Vector2.zero,
                ['lock-03'] = Vector2.zero,
                ['lock-04'] = Vector2.zero,
                ['lock-keyhole-circle'] = Vector2.zero,
                ['lock-keyhole-square'] = Vector2.zero,
                ['lock-unlocked'] = Vector2.zero,
                ['lock-unlocked-02'] = Vector2.zero,
                ['lock-unlocked-03'] = Vector2.zero,
                ['lock-unlocked-04'] = Vector2.zero,
                ['log-in'] = Vector2.zero,
                ['log-in-02'] = Vector2.zero,
                ['log-in-03'] = Vector2.zero,
                ['log-in-04'] = Vector2.zero,
                ['log-out'] = Vector2.zero,
                ['log-out-02'] = Vector2.zero,
                ['log-out-03'] = Vector2.zero,
                ['log-out-04'] = Vector2.zero,
                ['log-out-rounded'] = Vector2.zero,
                ['luggage'] = Vector2.zero,
                ['luggage-02'] = Vector2.zero,
                ['luggage-03'] = Vector2.zero,
                ['magic-wand'] = Vector2.zero,
                ['magic-wand-02'] = Vector2.zero,
                ['mail'] = Vector2.zero,
                ['mail-02'] = Vector2.zero,
                ['mail-03'] = Vector2.zero,
                ['mail-04'] = Vector2.zero,
                ['mail-05'] = Vector2.zero,
                ['mail-open'] = Vector2.zero,
                ['mail-open-02'] = Vector2.zero,
                ['map'] = Vector2.zero,
                ['map-02'] = Vector2.zero,
                ['mark'] = Vector2.zero,
                ['marker-pin'] = Vector2.zero,
                ['marker-pin-02'] = Vector2.zero,
                ['marker-pin-03'] = Vector2.zero,
                ['marker-pin-04'] = Vector2.zero,
                ['marker-pin-05'] = Vector2.zero,
                ['marker-pin-06'] = Vector2.zero,
                ['marker-pin-flag'] = Vector2.zero,
                ['maximize'] = Vector2.zero,
                ['maximize-02'] = Vector2.zero,
                ['medical-circle'] = Vector2.zero,
                ['medical-cross'] = Vector2.zero,
                ['medical-square'] = Vector2.zero,
                ['menu'] = Vector2.zero,
                ['menu-02'] = Vector2.zero,
                ['menu-03'] = Vector2.zero,
                ['menu-04'] = Vector2.zero,
                ['menu-05'] = Vector2.zero,
                ['message-alert-circle'] = Vector2.zero,
                ['message-alert-square'] = Vector2.zero,
                ['message-chat-circle'] = Vector2.zero,
                ['message-chat-square'] = Vector2.zero,
                ['message-check-circle'] = Vector2.zero,
                ['message-check-square'] = Vector2.zero,
                ['message-circle'] = Vector2.zero,
                ['message-circle-02'] = Vector2.zero,
                ['message-dots-circle'] = Vector2.zero,
                ['message-dots-square'] = Vector2.zero,
                ['message-heart-circle'] = Vector2.zero,
                ['message-heart-square'] = Vector2.zero,
                ['message-notification-circle'] = Vector2.zero,
                ['message-notification-square'] = Vector2.zero,
                ['message-plus-circle'] = Vector2.zero,
                ['message-plus-square'] = Vector2.zero,
                ['message-question-circle'] = Vector2.zero,
                ['message-question-square'] = Vector2.zero,
                ['message-smile-circle'] = Vector2.zero,
                ['message-smile-square'] = Vector2.zero,
                ['message-square'] = Vector2.zero,
                ['message-square-02'] = Vector2.zero,
                ['message-text-circle'] = Vector2.zero,
                ['message-text-circle-02'] = Vector2.zero,
                ['message-text-square'] = Vector2.zero,
                ['message-text-square-02'] = Vector2.zero,
                ['message-x-circle'] = Vector2.zero,
                ['message-x-square'] = Vector2.zero,
                ['microphone'] = Vector2.zero,
                ['microphone-02'] = Vector2.zero,
                ['microphone-off'] = Vector2.zero,
                ['microphone-off-02'] = Vector2.zero,
                ['microscope'] = Vector2.zero,
                ['minimize'] = Vector2.zero,
                ['minimize-02'] = Vector2.zero,
                ['minus'] = Vector2.zero,
                ['minus-circle'] = Vector2.zero,
                ['minus-square'] = Vector2.zero,
                ['mobile'] = Vector2.zero,
                ['modem'] = Vector2.zero,
                ['modem-02'] = Vector2.zero,
                ['monitor'] = Vector2.zero,
                ['monitor-02'] = Vector2.zero,
                ['monitor-03'] = Vector2.zero,
                ['monitor-04'] = Vector2.zero,
                ['monitor-05'] = Vector2.zero,
                ['moon'] = Vector2.zero,
                ['moon-02'] = Vector2.zero,
                ['moon-eclipse'] = Vector2.zero,
                ['moon-star'] = Vector2.zero,
                ['mouse'] = Vector2.zero,
                ['move'] = Vector2.zero,
                ['music-note'] = Vector2.zero,
                ['music-note-02'] = Vector2.zero,
                ['music-note-plus'] = Vector2.zero,
                ['navigation-pointer'] = Vector2.zero,
                ['navigation-pointer-02'] = Vector2.zero,
                ['navigation-pointer-off'] = Vector2.zero,
                ['navigation-pointer-off-02'] = Vector2.zero,
                ['notification-box'] = Vector2.zero,
                ['notification-message'] = Vector2.zero,
                ['notification-text'] = Vector2.zero,
                ['octagon'] = Vector2.zero,
                ['package'] = Vector2.zero,
                ['package-check'] = Vector2.zero,
                ['package-minus'] = Vector2.zero,
                ['package-plus'] = Vector2.zero,
                ['package-search'] = Vector2.zero,
                ['package-x'] = Vector2.zero,
                ['paint'] = Vector2.zero,
                ['paint-pour'] = Vector2.zero,
                ['palette'] = Vector2.zero,
                ['paperclip'] = Vector2.zero,
                ['paragraph-spacing'] = Vector2.zero,
                ['paragraph-wrap'] = Vector2.zero,
                ['passcode'] = Vector2.zero,
                ['passcode-lock'] = Vector2.zero,
                ['passport'] = Vector2.zero,
                ['pause-circle'] = Vector2.zero,
                ['pause-square'] = Vector2.zero,
                ['pen-tool'] = Vector2.zero,
                ['pen-tool-02'] = Vector2.zero,
                ['pen-tool-minus'] = Vector2.zero,
                ['pen-tool-plus'] = Vector2.zero,
                ['pencil'] = Vector2.zero,
                ['pencil-02'] = Vector2.zero,
                ['pencil-line'] = Vector2.zero,
                ['pentagon'] = Vector2.zero,
                ['percent'] = Vector2.zero,
                ['percent-02'] = Vector2.zero,
                ['percent-03'] = Vector2.zero,
                ['percent-circle'] = Vector2.zero,
                ['perspective'] = Vector2.zero,
                ['perspective-02'] = Vector2.zero,
                ['phone'] = Vector2.zero,
                ['phone-02'] = Vector2.zero,
                ['phone-call'] = Vector2.zero,
                ['phone-call-02'] = Vector2.zero,
                ['phone-hang-up'] = Vector2.zero,
                ['phone-incoming'] = Vector2.zero,
                ['phone-incoming-02'] = Vector2.zero,
                ['phone-outgoing'] = Vector2.zero,
                ['phone-outgoing-02'] = Vector2.zero,
                ['phone-pause'] = Vector2.zero,
                ['phone-plus'] = Vector2.zero,
                ['phone-x'] = Vector2.zero,
                ['pie-chart'] = Vector2.zero,
                ['pie-chart-02'] = Vector2.zero,
                ['pie-chart-03'] = Vector2.zero,
                ['pie-chart-04'] = Vector2.zero,
                ['piggy-bank'] = Vector2.zero,
                ['piggy-bank-02'] = Vector2.zero,
                ['pilcrow'] = Vector2.zero,
                ['pilcrow-02'] = Vector2.zero,
                ['pilcrow-square'] = Vector2.zero,
                ['pin'] = Vector2.zero,
                ['pin-02'] = Vector2.zero,
                ['pin-italic'] = Vector2.zero,
                ['placeholder'] = Vector2.zero,
                ['plane'] = Vector2.zero,
                ['play'] = Vector2.zero,
                ['play-circle'] = Vector2.zero,
                ['play-square'] = Vector2.zero,
                ['plus'] = Vector2.zero,
                ['plus-circle'] = Vector2.zero,
                ['plus-square'] = Vector2.zero,
                ['podcast'] = Vector2.zero,
                ['power'] = Vector2.zero,
                ['power-02'] = Vector2.zero,
                ['power-03'] = Vector2.zero,
                ['presentation-chart'] = Vector2.zero,
                ['presentation-chart-02'] = Vector2.zero,
                ['presentation-chart-03'] = Vector2.zero,
                ['printer'] = Vector2.zero,
                ['puzzle-piece'] = Vector2.zero,
                ['puzzle-piece-02'] = Vector2.zero,
                ['qr-code'] = Vector2.zero,
                ['qr-code-02'] = Vector2.zero,
                ['receipt'] = Vector2.zero,
                ['receipt-check'] = Vector2.zero,
                ['recording'] = Vector2.zero,
                ['recording-02'] = Vector2.zero,
                ['recording-03'] = Vector2.zero,
                ['reflect'] = Vector2.zero,
                ['reflect-02'] = Vector2.zero,
                ['refresh-ccw'] = Vector2.zero,
                ['refresh-ccw-02'] = Vector2.zero,
                ['refresh-ccw-03'] = Vector2.zero,
                ['refresh-ccw-04'] = Vector2.zero,
                ['refresh-ccw-05'] = Vector2.zero,
                ['refresh-ccw-double'] = Vector2.zero,
                ['refresh-ccw-vertical'] = Vector2.zero,
                ['refresh-ccw-vertical-md'] = Vector2.zero,
                ['refresh-ccw-vertical-sm'] = Vector2.zero,
                ['refresh-cw-02'] = Vector2.zero,
                ['refresh-cw-03'] = Vector2.zero,
                ['refresh-cw-04'] = Vector2.zero,
                ['refresh-cw-05'] = Vector2.zero,
                ['refresh-cw-right'] = Vector2.zero,
                ['repeat'] = Vector2.zero,
                ['repeat-02'] = Vector2.zero,
                ['repeat-03'] = Vector2.zero,
                ['repeat-04'] = Vector2.zero,
                ['reverse-left'] = Vector2.zero,
                ['reverse-right'] = Vector2.zero,
                ['right-indent'] = Vector2.zero,
                ['right-indent-02'] = Vector2.zero,
                ['rocket'] = Vector2.zero,
                ['rocket-02'] = Vector2.zero,
                ['roller-brush'] = Vector2.zero,
                ['route'] = Vector2.zero,
                ['rows'] = Vector2.zero,
                ['rows-02'] = Vector2.zero,
                ['rows-03'] = Vector2.zero,
                ['rss'] = Vector2.zero,
                ['rss-02'] = Vector2.zero,
                ['ruler'] = Vector2.zero,
                ['safe'] = Vector2.zero,
                ['sale'] = Vector2.zero,
                ['sale-02'] = Vector2.zero,
                ['sale-03'] = Vector2.zero,
                ['sale-04'] = Vector2.zero,
                ['save'] = Vector2.zero,
                ['save-02'] = Vector2.zero,
                ['save-03'] = Vector2.zero,
                ['save-double'] = Vector2.zero,
                ['scale'] = Vector2.zero,
                ['scale-02'] = Vector2.zero,
                ['scale-03'] = Vector2.zero,
                ['scales'] = Vector2.zero,
                ['scales-02'] = Vector2.zero,
                ['scan'] = Vector2.zero,
                ['school-compass'] = Vector2.zero,
                ['scissors'] = Vector2.zero,
                ['scissors-02'] = Vector2.zero,
                ['scissors-cut'] = Vector2.zero,
                ['scissors-cut-02'] = Vector2.zero,
                ['search-lg'] = Vector2.zero,
                ['search-md'] = Vector2.zero,
                ['search-refraction'] = Vector2.zero,
                ['search-sm'] = Vector2.zero,
                ['send'] = Vector2.zero,
                ['send-02'] = Vector2.zero,
                ['send-03'] = Vector2.zero,
                ['send-horizontal'] = Vector2.zero,
                ['send-vertical'] = Vector2.zero,
                ['server'] = Vector2.zero,
                ['server-02'] = Vector2.zero,
                ['server-03'] = Vector2.zero,
                ['server-04'] = Vector2.zero,
                ['server-05'] = Vector2.zero,
                ['server-06'] = Vector2.zero,
                ['settings'] = Vector2.zero,
                ['settings-02'] = Vector2.zero,
                ['settings-03'] = Vector2.zero,
                ['settings-04'] = Vector2.zero,
                ['settings-toggle'] = Vector2.zero,
                ['settings-toggle-line'] = Vector2.zero,
                ['share'] = Vector2.zero,
                ['share-02'] = Vector2.zero,
                ['share-03'] = Vector2.zero,
                ['share-04'] = Vector2.zero,
                ['share-05'] = Vector2.zero,
                ['share-06'] = Vector2.zero,
                ['share-07'] = Vector2.zero,
                ['shield'] = Vector2.zero,
                ['shield-02'] = Vector2.zero,
                ['shield-03'] = Vector2.zero,
                ['shield-dollar'] = Vector2.zero,
                ['shield-off'] = Vector2.zero,
                ['shield-plus'] = Vector2.zero,
                ['shield-separator'] = Vector2.zero,
                ['shield-tick'] = Vector2.zero,
                ['shield-zap'] = Vector2.zero,
                ['shop'] = Vector2.zero,
                ['shopping-bag'] = Vector2.zero,
                ['shopping-bag-02'] = Vector2.zero,
                ['shopping-bag-03'] = Vector2.zero,
                ['shopping-cart'] = Vector2.zero,
                ['shopping-cart-02'] = Vector2.zero,
                ['shopping-cart-03'] = Vector2.zero,
                ['shuffle'] = Vector2.zero,
                ['shuffle-02'] = Vector2.zero,
                ['signal'] = Vector2.zero,
                ['signal-02'] = Vector2.zero,
                ['signal-03'] = Vector2.zero,
                ['simcard'] = Vector2.zero,
                ['skew'] = Vector2.zero,
                ['skip-back'] = Vector2.zero,
                ['skip-forward'] = Vector2.zero,
                ['slash-circle-01'] = Vector2.zero,
                ['slash-circle-02'] = Vector2.zero,
                ['slash-divider'] = Vector2.zero,
                ['slash-octagon'] = Vector2.zero,
                ['sliders'] = Vector2.zero,
                ['sliders-02'] = Vector2.zero,
                ['sliders-03'] = Vector2.zero,
                ['sliders-04'] = Vector2.zero,
                ['snowflake'] = Vector2.zero,
                ['snowflake-02'] = Vector2.zero,
                ['spacing-height'] = Vector2.zero,
                ['spacing-height-02'] = Vector2.zero,
                ['spacing-width'] = Vector2.zero,
                ['spacing-width-02'] = Vector2.zero,
                ['speaker'] = Vector2.zero,
                ['speaker-02'] = Vector2.zero,
                ['speaker-03'] = Vector2.zero,
                ['speedometer'] = Vector2.zero,
                ['speedometer-02'] = Vector2.zero,
                ['speedometer-03'] = Vector2.zero,
                ['speedometer-04'] = Vector2.zero,
                ['square'] = Vector2.zero,
                ['stand'] = Vector2.zero,
                ['star'] = Vector2.zero,
                ['star-02'] = Vector2.zero,
                ['star-03'] = Vector2.zero,
                ['star-04'] = Vector2.zero,
                ['star-05'] = Vector2.zero,
                ['star-06'] = Vector2.zero,
                ['star-07'] = Vector2.zero,
                ['stars'] = Vector2.zero,
                ['stars-02'] = Vector2.zero,
                ['stars-03'] = Vector2.zero,
                ['sticker-circle'] = Vector2.zero,
                ['sticker-square'] = Vector2.zero,
                ['stop'] = Vector2.zero,
                ['stop-circle'] = Vector2.zero,
                ['stop-square'] = Vector2.zero,
                ['strikethrough'] = Vector2.zero,
                ['strikethrough-02'] = Vector2.zero,
                ['strikethrough-square'] = Vector2.zero,
                ['subscript'] = Vector2.zero,
                ['sun'] = Vector2.zero,
                ['sun-setting'] = Vector2.zero,
                ['sun-setting-02'] = Vector2.zero,
                ['sun-setting-03'] = Vector2.zero,
                ['sunrise'] = Vector2.zero,
                ['sunset'] = Vector2.zero,
                ['switch-horizontal'] = Vector2.zero,
                ['switch-horizontal-02'] = Vector2.zero,
                ['switch-horizontal-sm'] = Vector2.zero,
                ['switch-vertical'] = Vector2.zero,
                ['switch-vertical-02'] = Vector2.zero,
                ['switch-vertical-sm'] = Vector2.zero,
                ['table'] = Vector2.zero,
                ['tablet'] = Vector2.zero,
                ['tablet-02'] = Vector2.zero,
                ['tag'] = Vector2.zero,
                ['tag-02'] = Vector2.zero,
                ['tag-03'] = Vector2.zero,
                ['target'] = Vector2.zero,
                ['target-02'] = Vector2.zero,
                ['target-03'] = Vector2.zero,
                ['target-04'] = Vector2.zero,
                ['target-05'] = Vector2.zero,
                ['target-arrow'] = Vector2.zero,
                ['telescope'] = Vector2.zero,
                ['terminal'] = Vector2.zero,
                ['terminal-browser'] = Vector2.zero,
                ['terminal-circle'] = Vector2.zero,
                ['terminal-square'] = Vector2.zero,
                ['text-align-left'] = Vector2.zero,
                ['text-align-right'] = Vector2.zero,
                ['text-input'] = Vector2.zero,
                ['thermometer'] = Vector2.zero,
                ['thermometer-02'] = Vector2.zero,
                ['thermometer-03'] = Vector2.zero,
                ['thermometer-cold'] = Vector2.zero,
                ['thermometer-warm'] = Vector2.zero,
                ['thumbs-down'] = Vector2.zero,
                ['thumbs-up'] = Vector2.zero,
                ['ticket'] = Vector2.zero,
                ['ticket-02'] = Vector2.zero,
                ['toggle-01-left'] = Vector2.zero,
                ['toggle-01-right'] = Vector2.zero,
                ['toggle-02-left'] = Vector2.zero,
                ['toggle-02-right'] = Vector2.zero,
                ['toggle-03-left'] = Vector2.zero,
                ['toggle-03-right'] = Vector2.zero,
                ['toggle-left'] = Vector2.zero,
                ['toggle-right'] = Vector2.zero,
                ['toggle-rounded-left'] = Vector2.zero,
                ['toggle-rounded-right'] = Vector2.zero,
                ['tool'] = Vector2.zero,
                ['tool-02'] = Vector2.zero,
                ['train'] = Vector2.zero,
                ['tram'] = Vector2.zero,
                ['transform'] = Vector2.zero,
                ['translate'] = Vector2.zero,
                ['translate-02'] = Vector2.zero,
                ['trash'] = Vector2.zero,
                ['trash-02'] = Vector2.zero,
                ['trash-03'] = Vector2.zero,
                ['trash-04'] = Vector2.zero,
                ['trend-down'] = Vector2.zero,
                ['trend-down-02'] = Vector2.zero,
                ['trend-up'] = Vector2.zero,
                ['trend-up-02'] = Vector2.zero,
                ['triangle'] = Vector2.zero,
                ['trophy'] = Vector2.zero,
                ['trophy-02'] = Vector2.zero,
                ['truck'] = Vector2.zero,
                ['truck-02'] = Vector2.zero,
                ['tv'] = Vector2.zero,
                ['tv-02'] = Vector2.zero,
                ['tv-03'] = Vector2.zero,
                ['type'] = Vector2.zero,
                ['type-02'] = Vector2.zero,
                ['type-square'] = Vector2.zero,
                ['type-strikethrough'] = Vector2.zero,
                ['type-strikethrough-02'] = Vector2.zero,
                ['umbrella'] = Vector2.zero,
                ['umbrella-02'] = Vector2.zero,
                ['umbrella-03'] = Vector2.zero,
                ['underline'] = Vector2.zero,
                ['underline-02'] = Vector2.zero,
                ['underline-square'] = Vector2.zero,
                ['upload'] = Vector2.zero,
                ['upload-02'] = Vector2.zero,
                ['upload-03'] = Vector2.zero,
                ['upload-04'] = Vector2.zero,
                ['upload-circle'] = Vector2.zero,
                ['upload-circle-broken'] = Vector2.zero,
                ['upload-cloud'] = Vector2.zero,
                ['upload-cloud-02'] = Vector2.zero,
                ['usb-flash-drive'] = Vector2.zero,
                ['user'] = Vector2.zero,
                ['user-02'] = Vector2.zero,
                ['user-03'] = Vector2.zero,
                ['user-check'] = Vector2.zero,
                ['user-check-02'] = Vector2.zero,
                ['user-circle'] = Vector2.zero,
                ['user-down'] = Vector2.zero,
                ['user-down-02'] = Vector2.zero,
                ['user-edit'] = Vector2.zero,
                ['user-left'] = Vector2.zero,
                ['user-left-02'] = Vector2.zero,
                ['user-minus'] = Vector2.zero,
                ['user-minus-02'] = Vector2.zero,
                ['user-plus'] = Vector2.zero,
                ['user-plus-02'] = Vector2.zero,
                ['user-right'] = Vector2.zero,
                ['user-right-02'] = Vector2.zero,
                ['user-square'] = Vector2.zero,
                ['user-up'] = Vector2.zero,
                ['user-up-02'] = Vector2.zero,
                ['user-x'] = Vector2.zero,
                ['user-x-02'] = Vector2.zero,
                ['users'] = Vector2.zero,
                ['users-02'] = Vector2.zero,
                ['users-03'] = Vector2.zero,
                ['users-check'] = Vector2.zero,
                ['users-down'] = Vector2.zero,
                ['users-edit'] = Vector2.zero,
                ['users-left'] = Vector2.zero,
                ['users-minus'] = Vector2.zero,
                ['users-plus'] = Vector2.zero,
                ['users-right'] = Vector2.zero,
                ['users-up'] = Vector2.zero,
                ['users-x'] = Vector2.zero,
                ['variable'] = Vector2.zero,
                ['video-recorder'] = Vector2.zero,
                ['video-recorder-off'] = Vector2.zero,
                ['virus'] = Vector2.zero,
                ['voicemail'] = Vector2.zero,
                ['volume-max'] = Vector2.zero,
                ['volume-min'] = Vector2.zero,
                ['volume-minus'] = Vector2.zero,
                ['volume-plus'] = Vector2.zero,
                ['volume-x'] = Vector2.zero,
                ['wallet'] = Vector2.zero,
                ['wallet-02'] = Vector2.zero,
                ['wallet-03'] = Vector2.zero,
                ['wallet-04'] = Vector2.zero,
                ['wallet-05'] = Vector2.zero,
                ['watch-circle'] = Vector2.zero,
                ['watch-square'] = Vector2.zero,
                ['waves'] = Vector2.zero,
                ['webcam'] = Vector2.zero,
                ['webcam-02'] = Vector2.zero,
                ['wifi-off'] = Vector2.zero,
            },
        }
    end
    function __DARKLUA_BUNDLE_MODULES.E()
        local icons = {
            untitled = __DARKLUA_BUNDLE_MODULES.load('D'),
        }

        local function ProcessIconsMap(
            iconsList,
            iconsMap,
            image,
            iconSize,
            sizeOffset,
            columns
        )
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

            for i, v in iconsMap do
                table.insert(iconsList, i)
            end

            table.sort(iconsList)

            local columns = pack.columns

            if not columns then
                local totalIcons = 0

                for i, v in iconsMap do
                    totalIcons = totalIcons + 1
                end

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
                FontFace = Font.new('rbxasset://fonts/families/Ubuntu.json', (weight and {
                    (fontWeightMap[weight]),
                } or {
                    (Enum.FontWeight.Regular),
                })[1]),
                AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.new(0, 0, 0, 20),
                Text = props.content,
                TextColor3 = props.color or Color3.fromRGB(161, 161, 161),
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
                        (i > 1 and {
                            (Separator({
                                mode = source('horizontal'),
                            })),
                        } or {nil})[1],
                        Label({
                            content = section().name,
                            color = Color3.fromHSV(0, 0, 0.8),
                            size = 10,
                        }),
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
                create'UICorner'{
                    Name = 'UICorner',
                    CornerRadius = UDim.new(0, 6),
                },
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
                create'UIAspectRatioConstraint'{
                    Name = 'UIAspectRatioConstraint',
                },
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

                    if onComplete then
                        onComplete()
                    end
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

            if not character then
                return false
            end

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

            if not character then
                return
            end

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

            if duration then
                task.wait(duration)
            end
        end

        return Animal
    end
    function __DARKLUA_BUNDLE_MODULES.J()
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local create = vide.create
        local icons = __DARKLUA_BUNDLE_MODULES.load('E')

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
        local barBackground = Color3.fromHSV(0, 0, 0.4)

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
            check(props, {
                isFinalizer = 'boolean',
                size = 'number?',
            })

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
                character = {
                    controlled = false,
                    priority = 0,
                    owner = nil,
                },
                camera = {
                    controlled = false,
                    priority = 0,
                    owner = nil,
                },
            },
            timeouts = {},
            events = {},
        }

        function ControlManager:requestControl(
            owner,
            controlType,
            priority,
            timeout
        )
            local state = self.states[controlType]

            if not state then
                return false
            end
            if state.controlled and priority <= state.priority then
                return false
            end
            if state.controlled then
                self:releaseControl(controlType)
            end

            state.controlled = true
            state.priority = priority
            state.owner = owner

            if timeout then
                self.timeouts[controlType] = task.delay(timeout, function()
                    if state.owner == owner then
                        self:releaseControl(controlType)
                    end
                end)
            end

            self:emit('control_taken', {
                controlType = controlType,
                owner = owner,
                priority = priority,
            })

            return true
        end
        function ControlManager:releaseControl(controlType, owner)
            local state = self.states[controlType]

            if not state or not state.controlled then
                return
            end
            if owner and state.owner ~= owner then
                return
            end

            local oldOwner = state.owner

            state.controlled = false
            state.priority = 0
            state.owner = nil

            if self.timeouts[controlType] then
                task.cancel(self.timeouts[controlType])

                self.timeouts[controlType] = nil
            end

            self:emit('control_released', {
                controlType = controlType,
                owner = oldOwner,
            })
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

            for _, callback in ipairs(listeners)do
                task.spawn(callback, data)
            end
        end
        function ControlManager:on(event, callback)
            if not self.events[event] then
                self.events[event] = {}
            end

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
                if not props.controlPriority then
                    return true
                end

                local acquired = {}

                for controlType, priority in pairs(props.controlPriority)do
                    if ControlManager:requestControl(ownerId, controlType, priority, props.controlTimeout) then
                        table.insert(acquired, controlType)
                    else
                        for _, acquiredType in ipairs(acquired)do
                            ControlManager:releaseControl(acquiredType, ownerId)
                        end

                        return false
                    end
                end

                return true
            end
            local function hasRequiredControl()
                if not props.controlPriority then
                    return true
                end

                for controlType, priority in pairs(props.controlPriority)do
                    if not ControlManager:hasControl(ownerId, controlType) then
                        return false
                    end
                end

                return true
            end
            local function releaseAllControls()
                if not props.controlPriority then
                    return
                end

                for controlType, _ in pairs(props.controlPriority)do
                    ControlManager:releaseControl(controlType, ownerId)
                end
            end

            local whenCheckedConnections = {}

            local function addWhenCheckedConnection(connection)
                table.insert(whenCheckedConnections, connection)
            end
            local function cleanupWhenChecked()
                for _, connection in ipairs(whenCheckedConnections)do
                    if connection.Connected then
                        connection:Disconnect()
                    end
                end

                whenCheckedConnections = {}
            end
            local function whileCheckedLoop()
                local WhileChecked = props.WhileChecked

                if not WhileChecked then
                    return
                end

                while isChecked() do
                    local hasRequired = hasRequiredControl()

                    if hasRequired or requestAllControls() then
                        local returnValue = WhileChecked()

                        if returnValue == false then
                            releaseAllControls()
                        end
                    end

                    task.wait()
                end
            end
            local function onCheckedChanged(newState)
                if props.OnChanged then
                    task.spawn(props.OnChanged, newState)
                end
                if newState then
                    if props.WhenChecked then
                        task.spawn(props.WhenChecked, addWhenCheckedConnection)
                    end

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
                Label({
                    content = props.label,
                }),
                create'ImageButton'{
                    Name = 'CheckButton',
                    BackgroundColor3 = Color3.fromHSV(0, 0, 1),
                    BackgroundTransparency = 0,
                    Size = UDim2.fromOffset(18, 18),
                    Activated = function()
                        if not isDisabled() then
                            isChecked(not isChecked())
                        end
                    end,
                    create'UICorner'{
                        CornerRadius = UDim.new(0, 6),
                    },
                    Icon({
                        icon = {
                            image = 'rbxassetid://84900867946882',
                            size = Vector2.zero,
                            position = Vector2.zero,
                        },
                        color = Color3.new(0, 0, 0),
                        size = 10,
                    }),
                    create'UIFlexItem'{},
                },
            }

            effect(function()
                local transparency = isDisabled() and 0.5 or 0

                checkboxFrame.CheckButton.Active = not isDisabled()
                checkboxFrame.CheckButton.Transparency = transparency
                checkboxFrame.Label.TextTransparency = transparency
            end)
            effect(function()
                local isCheckedValue = isChecked()
                local color = isCheckedValue and Color3.new(1, 1, 1) or Color3.fromRGB(40, 40, 40)

                checkboxFrame.CheckButton.BackgroundColor3 = color
                checkboxFrame.CheckButton.Icon.Visible = isCheckedValue
            end)

            if not childs then
                return checkboxFrame
            end

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
                        TreeChildTrail({
                            isFinalizer = i == #childs(),
                        }),
                        child(),
                    }
                end),
            }
        end

        return Checkbox
    end
    function __DARKLUA_BUNDLE_MODULES.Q()
        local Segment = {}

        function Segment.GenerateCirclePoints(
            centerPosition,
            radius,
            resolution
        )
            local circumference = 2 * math.pi * radius
            local numPoints = math.max(3, math.floor(circumference / resolution))
            local angleStep = (2 * math.pi) / numPoints
            local points = {}

            for i = 0, numPoints - 1 do
                local angle = i * angleStep
                local x = centerPosition.X + radius * math.cos(angle)
                local z = centerPosition.Z + radius * math.sin(angle)
                local point = Vector3.new(x, centerPosition.Y, z)

                table.insert(points, point)
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
                    if not checkcaller() then
                        return true
                    end
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
            if p94 then
                if p94:GetAttribute('IsCarrying') then
                    return
                elseif p95 or not p94:GetAttribute('MovementDisabled') then
                    if p94:FindFirstChild('Head') then
                        local v96 = p94:GetAttribute('AnimalType')
                        local v97 = p94:GetAttribute('AnimalName')

                        if v96 and (v97 and p94:GetAttribute('AnimalAge')) then
                            local v98 = AnimalConfig[v96][v97]
                            local v99 = Utils.CanEatDrink.DetectMeatGrassWater(p94, v98)
                            local v100 = v99 == 'Drink' and 'Drinking' or 'Eating'

                            return v98.EnableLeavesEating and Utils.DetectLeaves(p94) or (v98.EnableInsectEating and Utils.DetectInsects(p94) or v99)
                        else
                            warn("Not spawned as animal, so we can't check eat/drink")
                        end
                    else
                        return
                    end
                else
                    return
                end
            else
                return
            end
        end

        local grassResolution = 4
        local grassHeightOffset = Vector3.new(0, 40, 0)
        local grassRayDirection = Vector3.new(0, -80, 0)
        local SegmentCircle = __DARKLUA_BUNDLE_MODULES.load('Q')
        local Grass = Enum.Material.Grass
        local grassRayParams = RaycastParams.new()

        grassRayParams.FilterType = Enum.RaycastFilterType.Include
        grassRayParams.FilterDescendantsInstances = {
            workspace.Terrain,
        }

        local grassStartingRadius = 6
        local grassMaxRadius = grassStartingRadius * 8

        local function FindNearestGrass(at, radius)
            local points = SegmentCircle.GenerateCirclePoints(at + grassHeightOffset, radius, grassResolution)

            for i, v in points do
                local result = workspace:Raycast(v, grassRayDirection, grassRayParams)

                if result and result.Material == Grass then
                    return result.Position
                end
            end

            if radius == grassMaxRadius then
                return
            end

            return FindNearestGrass(at, radius * 2)
        end

        local waterResolution = 12
        local waterHeightOffset = Vector3.new(0, 80, 0)
        local waterRayDirection = Vector3.new(0, -160, 0)
        local Water = Enum.Material.Water
        local waterRayParams = RaycastParams.new()

        waterRayParams.FilterType = Enum.RaycastFilterType.Include
        waterRayParams.FilterDescendantsInstances = {
            workspace.Terrain,
        }

        local waterStartingRadius = 12
        local waterMaxRadius = 384

        local function FindNearestWaterShore(at, radius)
            local points = SegmentCircle.GenerateCirclePoints(at + waterHeightOffset, radius, waterResolution)
            local bestPosition = nil
            local bestDistance = math.huge

            for i, v in points do
                local result = workspace:Raycast(v, waterRayDirection, waterRayParams)

                if result and result.Material == Water then
                    local flatDirection = Vector3.new(result.Position.X - at.X, 0, result.Position.Z - at.Z)
                    local flatDistance = flatDirection.Magnitude
                    local shorePosition = result.Position

                    if flatDistance > 0 then
                        shorePosition = result.Position - flatDirection.Unit * math.min(2, flatDistance)
                    end

                    if flatDistance < bestDistance then
                        bestDistance = flatDistance
                        bestPosition = shorePosition
                    end
                end
            end

            if bestPosition then
                return bestPosition
            end

            if radius >= waterMaxRadius then
                return
            end

            return FindNearestWaterShore(at, math.min(radius * 2, waterMaxRadius))
        end

        local player = game:GetService('Players').LocalPlayer
        local Checkbox = __DARKLUA_BUNDLE_MODULES.load('M')
        local LerpTween = __DARKLUA_BUNDLE_MODULES.load('H')
        local vide = __DARKLUA_BUNDLE_MODULES.load('x')
        local source = vide.source
        local goToNearestSource = source(true)

        -- Expose eat/drink toggle sources so the growth loop can cycle them on new slot spawn
        local autoEatChecked = source(false)
        local autoDrinkChecked = source(false)
        local autoEatCarcassChecked = source(false)
        shared._autoEatChecked = autoEatChecked
        shared._autoDrinkChecked = autoDrinkChecked
        shared._autoEatCarcassChecked = autoEatCarcassChecked

        local lastDrinkMoveAt = 0
        local DRINK_MOVE_COOLDOWN = 1.5

        local function getWaterVerticalGoal(rootPosition)
            local waterPart = workspace:FindFirstChild("MainWaterPart")
            if waterPart and waterPart:IsA("BasePart") then
                return CFrame.new(rootPosition.X, waterPart.Position.Y, rootPosition.Z)
            end

            local waterPosition = FindNearestWaterShore(rootPosition, waterStartingRadius)
            if waterPosition then
                return CFrame.new(rootPosition.X, waterPosition.Y, rootPosition.Z)
            end
        end

        return {
            Checkbox({
                label = 'Auto eat',
                isChecked = autoEatChecked,
                controlPriority = {character = 2},
                WhileChecked = function()
                    local character = player.Character

                    if not character then
                        return
                    end
                    -- Block during growth reset so we don't fight the reset cycle
                    if shared._inGrowthReset then return false end
                    if shared._inCarcassEat then return false end
                    -- CARNIVORE BLOCK: NEVER auto-eat grass for carnivores
                    -- (silently skip instead of force-unchecking — lets user keep the box toggled)
                    local animalName = character:GetAttribute("AnimalName") or ""
                    local CARNIVORES = { Lion=true, Tiger=true, Cheetah=true, Crocodile=true, Leopard=true }
                    if CARNIVORES[animalName] then
                        return false
                    end
                    -- Water priority: only block eating while an active drink-to-full cycle is running
                    -- (flag is set when water hits <=55%, cleared when it reaches 100%)
                    if character:GetAttribute('_drinkingToFull') then
                        return
                    end
                    if (character:GetAttribute('Food') or 0) < 90 then
                        local ingestionAvaliable = CanStartEatDrink(character)

                        if ingestionAvaliable == 'Eat' then
                            SetClientSubStateChangesEnabled(false)
                            ChangeCharacterSubState('Eating')
                        elseif goToNearestSource() then
                            local root = character:FindFirstChild("HumanoidRootPart")
                            if not root then return end
                            local rootPosition = root.Position
                            local grassPosition = FindNearestGrass(rootPosition, grassStartingRadius)

                            if not grassPosition then
                                return
                            end

                            local humanoid = character:FindFirstChild("Humanoid")
                            if not humanoid then return end
                            local heightVector = Vector3.new(0, humanoid.HipHeight, 0)
                            local goalPosition = grassPosition + heightVector
                            local direction = (goalPosition - rootPosition)

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
                controlPriority = {character = 3},
                WhileChecked = (function()
                    -- State lives outside WhileChecked so it persists between ticks
                    local isBusy    = false
                    local RS2       = game:GetService("ReplicatedStorage")
                    local eatRemote = RS2:WaitForChild("StartEatingCarcassesRemotEvent", 10)
                    local subStateRF = RS2:WaitForChild("AskServerToSetSubStateRemoteFunction", 10)
                    local lastCarcassTime = 0  -- Prevent rapid re-TP to same carcass
                    local lastEatEndTime = 0   -- Cooldown after finishing an eat cycle
                    local EAT_COOLDOWN   = 6   -- seconds to wait before another eat cycle

                    local function getCarcassRoot(c)
                        return c:FindFirstChild("HumanoidRootPart")
                            or c:FindFirstChildWhichIsA("BasePart", true)
                    end

                    -- PROPER RAGDOLL TELEPORT (from confirmedTP)
                    -- RAGDOLL TP — mirrors confirmedTP from growth loop:
                    -- ragdoll -> loop SetPrimaryPartCFrame -> wait -> GettingUp -> verify -> retry
                    local TP_TOLERANCE = 12
                    local function ragdollTeleportToPos(character, targetPos, maxAttempts)
                        maxAttempts = maxAttempts or 6
                        for attempt = 1, maxAttempts do
                            local root = character:FindFirstChild("HumanoidRootPart")
                            local hum  = character:FindFirstChild("Humanoid")
                            if not root or not hum then
                                task.wait(1)
                            else
                                Animal.CancelTween(true)
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
                                for _ = 1, 10 do
                                    character:SetAttribute("MovementDisabled", false)
                                    task.wait(0.1)
                                end
                                -- Verify position
                                local r = character:FindFirstChild("HumanoidRootPart")
                                if r then
                                    local dist = (r.Position - targetPos).Magnitude
                                    print(string.format("[CarcassEat] TP attempt %d — dist: %.1f studs", attempt, dist))
                                    if dist <= TP_TOLERANCE then
                                        print("[CarcassEat] TP confirmed on attempt " .. attempt)
                                        return true
                                    else
                                        warn("[CarcassEat] Too far (" .. string.format("%.1f", dist) .. " studs) — retrying")
                                    end
                                end
                            end
                        end
                        warn("[CarcassEat] TP failed after " .. maxAttempts .. " attempts — continuing anyway")
                        return false
                    end

                    return function()
                        if isBusy then return end
                        if (tick() - lastEatEndTime) < EAT_COOLDOWN then return end
                        if shared._inGrowthReset then return end  -- growth loop is mid-reset

                        local character = player.Character
                        if not character then return end

                        -- WATER PRIORITY: if water <= 30, let auto drink recover to 100 first.
                        -- This stops carcass eat from interrupting an emergency drink session.
                        local curWater = character:GetAttribute("Water") or 100
                        if curWater <= 30 then
                            -- Make sure drink-to-full flag is set so auto drink doesn't bail
                            character:SetAttribute('_drinkingToFull', true)
                            return false
                        end

                        -- 100% GROWTH BLOCK: stop teleporting to carcasses once fully grown.
                        -- Growth loop will handle the war-spawn TP / reset cycle from here.
                        local growth = character:GetAttribute("GrowthPercentage") or 0
                        if growth >= 1 then
                            return false
                        end

                        local animalName = character:GetAttribute("AnimalName") or ""
                        -- CARCASS EAT: ONLY for carnivores (Lion, Tiger, Cheetah, Crocodile, Leopard)
                        local CARNIVORES = { Lion=true, Tiger=true, Cheetah=true, Crocodile=true, Leopard=true }
                        if not CARNIVORES[animalName] then
                            return false
                        end

                        local food = character:GetAttribute("Food") or 0
                        if food >= 90 then return false end

                        local carcassStorage = workspace:FindFirstChild("CarcassesStorageModel")
                        if not carcassStorage then return false end

                        local root = character:FindFirstChild("HumanoidRootPart")
                        if not root then return end

                        -- Find nearest carcass — IMPROVED: large range + GetDescendants (catches nested carcasses)
                        local nearest, nearestDist = nil, math.huge
                        local MAX_CARCASS_RANGE = 2500  -- studs

                        -- Build list of candidate carcass models (direct children AND any nested models with HRP)
                        local candidates = {}
                        for _, child in carcassStorage:GetChildren() do
                            table.insert(candidates, child)
                        end
                        -- Also scan descendants for anything that looks like a carcass model
                        for _, desc in carcassStorage:GetDescendants() do
                            if desc:IsA("Model") and desc:FindFirstChild("HumanoidRootPart") then
                                table.insert(candidates, desc)
                            end
                        end
                        -- FALLBACK for multi-player: also scan workspace for any Model named like a carcass
                        -- (when another player is actively eating, the game may reparent the carcass)
                        for _, desc in workspace:GetDescendants() do
                            if desc:IsA("Model")
                                and desc:FindFirstChild("HumanoidRootPart")
                                and (desc.Name:lower():find("carcass") or desc.Name:lower():find("dead"))
                                and desc.Parent ~= carcassStorage then
                                table.insert(candidates, desc)
                            end
                        end

                        for _, carcass in candidates do
                            local cRoot = getCarcassRoot(carcass)
                            if cRoot then
                                local dist = (root.Position - cRoot.Position).Magnitude
                                if dist < nearestDist and dist < MAX_CARCASS_RANGE then
                                    nearest = carcass
                                    nearestDist = dist
                                end
                            end
                        end
                        if not nearest then return false end

                        local cRoot = getCarcassRoot(nearest)
                        if not cRoot then return false end

                        if not eatRemote then
                            warn("[CarcassEat] StartEatingCarcassesRemotEvent not found in ReplicatedStorage")
                            return false
                        end

                        isBusy = true
                        shared._inCarcassEat = true  -- blocks growth loop from firing war TP while we eat
                        print("[CarcassEat] Targeting:", nearest.Name, "dist:", math.floor(nearestDist), "food:", food)

                        -- Top priority — stop drink
                        character:SetAttribute('_drinkingToFull', false)

                        local hum = character:FindFirstChild("Humanoid")
                        Animal.CancelTween(true)

                        -- TP with RAGDOLL to carcass location (prevents anti-cheat teleport back)
                        local cPos = cRoot.Position
                        local standPos = Vector3.new(cPos.X, cPos.Y + 2, cPos.Z)
                        ragdollTeleportToPos(character, standPos)
                        task.wait(0.4)

                        -- Anchor briefly so we can't slide off the carcass on slopes (Jungle Life)
                        local anchorRoot = character:FindFirstChild("HumanoidRootPart")
                        if anchorRoot then anchorRoot.Anchored = true end

                        -- Upright before eating
                        if hum then
                            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                            task.wait(0.2)
                        end

                        -- Trigger substate via InvokeServer (same as game uses)
                        SetClientSubStateChangesEnabled(false)
                        pcall(function()
                            subStateRF:InvokeServer("Eating")
                        end)
                        task.wait(0.3)

                        -- Fire eat remote
                        local ok, err = pcall(function()
                            eatRemote:FireServer(nearest)
                        end)
                        if ok then
                            print("[CarcassEat] Fired — waiting for food to tick up")
                        else
                            warn("[CarcassEat] FireServer error:", tostring(err))
                        end

                        -- Stay anchored until BOTH:
                        --   1) food has started rising (proves eat animation is running)
                        --   2) humanoid state is no longer ragdolled (Running / Idle / GettingUp finished)
                        -- Otherwise releasing while still in Physics state makes us slide off.
                        local startFood = character:GetAttribute("Food") or 0
                        local anchorReleased = false
                        local releaseDeadline = tick() + 5  -- safety: release after 5s no matter what
                        local foodRose = false
                        local RAGDOLL_STATES = {
                            [Enum.HumanoidStateType.Physics]      = true,
                            [Enum.HumanoidStateType.FallingDown]  = true,
                            [Enum.HumanoidStateType.Ragdoll]      = true,
                            [Enum.HumanoidStateType.Freefall]     = true,
                            [Enum.HumanoidStateType.GettingUp]    = true,
                        }
                        while not anchorReleased do
                            task.wait(0.15)
                            local curChar = player.Character
                            if not curChar or curChar ~= character then break end
                            local curHum = curChar:FindFirstChildOfClass("Humanoid")
                            local curFood = curChar:GetAttribute("Food") or 0
                            if curFood > startFood then foodRose = true end

                            -- Re-fire eat in case the first fire didn't catch
                            pcall(function() eatRemote:FireServer(nearest) end)
                            -- Keep nudging humanoid out of ragdoll while anchored
                            if curHum then
                                local st = curHum:GetState()
                                if RAGDOLL_STATES[st] then
                                    curHum:ChangeState(Enum.HumanoidStateType.GettingUp)
                                end
                            end

                            -- Both conditions met: food rising AND not in a ragdolled state
                            if curHum and foodRose and not RAGDOLL_STATES[curHum:GetState()] then
                                local relRoot = curChar:FindFirstChild("HumanoidRootPart")
                                if relRoot then
                                    Animal.CancelTween(true)
                                    -- Zero velocity BEFORE unanchoring to prevent fling
                                    -- (anchored parts accumulate physics force; releasing
                                    -- without zeroing yeets you across the map)
                                    relRoot.AssemblyLinearVelocity = Vector3.zero
                                    relRoot.AssemblyAngularVelocity = Vector3.zero
                                    relRoot.Anchored = false
                                end
                                anchorReleased = true
                                print("[CarcassEat] Anchor released — food:", curFood, "state:", curHum:GetState().Name)
                            elseif tick() > releaseDeadline then
                                -- Safety release
                                local relRoot = curChar:FindFirstChild("HumanoidRootPart")
                                if relRoot then
                                    Animal.CancelTween(true)
                                    relRoot.AssemblyLinearVelocity = Vector3.zero
                                    relRoot.AssemblyAngularVelocity = Vector3.zero
                                    relRoot.Anchored = false
                                end
                                anchorReleased = true
                                print("[CarcassEat] Anchor safety-released after timeout")
                            end
                        end

                        -- Monitor food rising — stay idle while the game is ticking food up,
                        -- so we don't re-TP and knock the lion off the carcass mid-eat.
                        local lastFood = character:GetAttribute("Food") or 0
                        local stallTicks = 0
                        local MAX_STALL = 6   -- ~3 seconds of no rise = stop monitoring
                        while true do
                            task.wait(0.5)
                            local curChar = player.Character
                            if not curChar or curChar ~= character then break end
                            local curFood = curChar:GetAttribute("Food") or 0
                            if curFood >= 95 then
                                print("[CarcassEat] Food full — done")
                                break
                            end
                            if curFood > lastFood then
                                -- Still eating, reset stall counter
                                lastFood = curFood
                                stallTicks = 0
                                -- Re-fire eat remote periodically to keep game in eat state
                                pcall(function() eatRemote:FireServer(nearest) end)
                            else
                                stallTicks = stallTicks + 1
                                if stallTicks >= MAX_STALL then
                                    print("[CarcassEat] Food stalled at " .. curFood .. " — ending monitor")
                                    break
                                end
                            end
                            -- Safety: if the carcass is gone (eaten up), bail
                            if not nearest.Parent then
                                print("[CarcassEat] Carcass gone — ending monitor")
                                break
                            end
                        end

                        SetClientSubStateChangesEnabled(true)
                        task.wait(0.5)

                        -- Safety: make sure we're not still anchored when exiting
                        local safetyRoot = character:FindFirstChild("HumanoidRootPart")
                        if safetyRoot and safetyRoot.Anchored then
                            Animal.CancelTween(true)
                            safetyRoot.AssemblyLinearVelocity = Vector3.zero
                            safetyRoot.AssemblyAngularVelocity = Vector3.zero
                            safetyRoot.Anchored = false
                            print("[CarcassEat] Safety unanchor at exit")
                        end

                        if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
                        for _ = 1, 5 do
                            character:SetAttribute("MovementDisabled", false)
                            task.wait(0.1)
                        end

                        local food2 = character:GetAttribute("Food") or 0
                        print("[CarcassEat] Food after eat:", food2)

                        -- Check for more carcasses (GetDescendants to catch nested)
                        local hasMore = false
                        for _, c in carcassStorage:GetDescendants() do
                            if c:IsA("Model") and c ~= nearest and getCarcassRoot(c) then
                                hasMore = true
                                break
                            end
                        end

                        -- DO NOT teleport back to grow spawn — that was causing the "war location" glitch
                        -- where the growth loop detected the returned position and fired a war TP.
                        -- Just stay at the carcass spot; the growth loop is blocked while _inCarcassEat is true.
                        if hasMore then
                            print("[CarcassEat] More carcasses — looping")
                        else
                            print("[CarcassEat] No more carcasses in range")
                        end

                        shared._inCarcassEat = false  -- release growth loop
                        lastEatEndTime = tick()        -- start cooldown before next eat cycle
                        isBusy = false
                    end
                end)(),
            }),
            Checkbox({
                label = 'Auto drink',
                isChecked = autoDrinkChecked,
                controlPriority = {character = 2},
                WhileChecked = function()
                    local character = player.Character

                    if not character then return end

                    -- Block during growth reset so we don't fight the reset cycle
                    if shared._inGrowthReset then
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end
                    if shared._inCarcassEat then
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end

                    -- Block 100% auto drink by default so normal war/reset flow
                    -- never drags a finished slot into water. Parking mode is the
                    -- one exception because AFK passive-coin farming needs drink on.
                    local growth = character:GetAttribute("GrowthPercentage") or 0
                    if growth >= 1 and not shared._parkingModeActive then
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                    end

                    -- Savannah can wait longer; Jungle keeps the safer early drink trigger.
                    local water = character:GetAttribute('Water') or 0
                    local drinkTrigger = shared._growthGameName == "SavannahLife" and 55 or 90
                    if water <= drinkTrigger then
                        character:SetAttribute('_drinkingToFull', true)
                    end
                    if water >= 100 then
                        -- LION/TIGER: TP straight back to grow spawn so we don't drown.
                        -- Other animals stop drink movement here, matching the older stable script.
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
                                for _ = 1, 6 do
                                    character:SetAttribute("MovementDisabled", false)
                                    task.wait(0.1)
                                end
                            end
                            character:SetAttribute('_drinkingToFull', false)
                            return false
                        end
                        do
                            Animal.CancelTween(true)
                            character:SetAttribute('_drinkingToFull', false)
                            return false
                        end
                        --[[
                        -- Exit water to nearest grass so we don't drown
                        -- Only move if hunger is also fine (>90), otherwise auto eat handles movement
                        local food = character:GetAttribute('Food') or 0
                        if food > 90 then
                            local root = character:FindFirstChild('HumanoidRootPart')
                            if root then
                                local rootPosition = root.Position
                                local grassParams = RaycastParams.new()
                                grassParams.FilterType = Enum.RaycastFilterType.Include
                                grassParams.FilterDescendantsInstances = { workspace.Terrain }
                                local grassGoal = nil
                                local searchDirs = {
                                    Vector3.new(1,0,0), Vector3.new(-1,0,0),
                                    Vector3.new(0,0,1), Vector3.new(0,0,-1),
                                    Vector3.new(1,0,1).Unit, Vector3.new(-1,0,1).Unit,
                                    Vector3.new(1,0,-1).Unit, Vector3.new(-1,0,-1).Unit,
                                }
                                for _, dir in searchDirs do
                                    for dist = 4, 80, 4 do
                                        local probe = rootPosition + dir * dist
                                        local hit = workspace:Raycast(probe + Vector3.new(0, 5, 0), Vector3.new(0, -20, 0), grassParams)
                                        if hit and hit.Material == Enum.Material.Grass then
                                            grassGoal = CFrame.new(probe, probe + dir)
                                            break
                                        end
                                    end
                                    if grassGoal then break end
                                end
                                if grassGoal then
                                    Animal.TweenToAsync(grassGoal)
                                end
                            end
                        end
                        character:SetAttribute('_drinkingToFull', false)
                        return false
                        ]]
                    end
                    if not character:GetAttribute('_drinkingToFull') then
                        return false
                    end

                    local ingestionAvaliable = CanStartEatDrink(character, true)

                    if ingestionAvaliable == 'Eat' then
                        ingestionAvaliable = nil
                    end

                    if ingestionAvaliable == 'Drink' then
                        Animal.CancelTween(true)
                        SetClientSubStateChangesEnabled(false)
                        ChangeCharacterSubState('Drinking')
                    elseif goToNearestSource() then
                        local root = character:FindFirstChild("HumanoidRootPart")
                        local humanoid = character:FindFirstChild("Humanoid")

                        if not root then
                            return
                        end

                        if root.Anchored then
                            root.Anchored = false
                        end
                        if humanoid then
                            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                        end

                        local rootPosition = root.Position
                        do
                            local waterGoal = getWaterVerticalGoal(rootPosition)
                            if waterGoal then
                                local distance = (waterGoal.Position - rootPosition).Magnitude
                                if distance > 1 and tick() - lastDrinkMoveAt >= DRINK_MOVE_COOLDOWN then
                                    lastDrinkMoveAt = tick()
                                    Animal.TweenToAsync(waterGoal)
                                else
                                    task.wait(0.25)
                                end
                            else
                                return false
                            end
                            return
                        end
                        --[[
                        if shoreGoal then
                            Animal.TweenToAsync(shoreGoal)
                        else
                            -- fallback: use water surface Y but stay just above it
                            local waterPart = workspace:FindFirstChild("MainWaterPart")
                            if waterPart and waterPart:IsA("BasePart") then
                                local waterPosition = waterPart.Position + Vector3.new(0, 2, 0)
                                Animal.TweenToAsync(CFrame.new(waterPosition))
                            else
                                -- No MainWaterPart found â€” scan further out for water terrain
                                local farShore = nil
                                for _, dir in directions do
                                    for dist = 4, 200, 8 do
                                        local probe = rootPosition + dir * dist
                                        local hit = workspace:Raycast(probe + Vector3.new(0, 40, 0), Vector3.new(0, -80, 0), waterParams)
                                        if hit and hit.Material == Enum.Material.Water then
                                            local shore = rootPosition + dir * math.max(dist - 2, 0)
                                            farShore = CFrame.new(shore, shore + dir)
                                            break
                                        end
                                    end
                                    if farShore then break end
                                end
                                if farShore then
                                    Animal.TweenToAsync(farShore)
                                end
                            end
                        end
                        ]]
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
                    -- Persistent debounce counter for Lion/Tiger only.
                    -- Need N consecutive detections before nudging, so false
                    -- positives don't cause constant surface-snapping.
                    local lionTerrainStreak = 0
                    local LION_TERRAIN_REQUIRED = 5  -- ~5 consecutive ticks before trigger

                    return function()
                        local character = player.Character
                        if not character then return end
                        local root = character:FindFirstChild("HumanoidRootPart")
                        if not root then return end

                        if shared._animalTweening then
                            lionTerrainStreak = 0
                            return false
                        end

                        local animalName = character:GetAttribute("AnimalName") or ""
                        local isLionOrTiger = (animalName == "Lion" or animalName == "Tiger")

                        if Animal.IsInsideTerrain() then
                            if isLionOrTiger then
                                -- Debounced path — need several consecutive hits
                                lionTerrainStreak = lionTerrainStreak + 1
                                if lionTerrainStreak < LION_TERRAIN_REQUIRED then
                                    return  -- wait for more confirmations
                                end
                                lionTerrainStreak = 0
                                -- Bigger nudge for Lion/Tiger since we only fire occasionally
                                root.CFrame = CFrame.new(root.Position + Vector3.new(0, 8, 0))
                            else
                                -- Herbivores/Gorilla: current aggressive behavior (fire every tick)
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
                    if shared._setGrowNewSlots then
                        shared._setGrowNewSlots(state)
                    end
                end,
            }),
            Checkbox({
                label = 'Grow existing slots',
                isChecked = source(false),
                OnChanged = function(state)
                    if shared._setGrowExistingSlots then
                        shared._setGrowExistingSlots(state)
                    end
                end,
            }),
            Checkbox({
                label = 'Passive coins (parking mode)',
                isChecked = source(false),
                OnChanged = function(state)
                    if shared._setParkingMode then
                        shared._setParkingMode(state)
                    end
                end,
            }),
        }
    end
    function __DARKLUA_BUNDLE_MODULES.T()
        local icons = __DARKLUA_BUNDLE_MODULES.load('E')

        return {
            icon = icons.untitled.icons['user-02'],
            sections = {
                {
                    name = 'Eat-drink',
                    content = __DARKLUA_BUNDLE_MODULES.load('R'),
                },
                {
                    name = 'Misc',
                    content = __DARKLUA_BUNDLE_MODULES.load('S'),
                },
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

local vide = __DARKLUA_BUNDLE_MODULES.load('x')
local source = vide.source
local create = vide.create
local root = vide.root
local Window = __DARKLUA_BUNDLE_MODULES.load('C')
local Category = __DARKLUA_BUNDLE_MODULES.load('G')

function App()
    local categories = {}
    local containers = {}
    local isOpenedSources = {}

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

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local destroy

destroy = root(function()
    local app = App()

    app.Parent = game:GetService('CoreGui')
    app.ZIndexBehavior = Enum.ZIndexBehavior.Global
    shared.LECleanup = function()
        destroy()
        app:Destroy()
    end
end)
-- Anti-AFK (auto-on)
-- Layer 1: fires on Roblox Idled event
task.spawn(function()
    local VirtualUser = game:GetService("VirtualUser")
    game:GetService("Players").LocalPlayer.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end)
-- Anti-AFK Layer 2: proactive — nudges camera + virtual input every 4 minutes
-- bypasses games that use their own kick timer independent of Roblox's Idled event
task.spawn(function()
    local VirtualUser = game:GetService("VirtualUser")
    local camera = workspace.CurrentCamera
    while true do
        task.wait(240) -- every 4 minutes
        -- Small camera nudge
        pcall(function()
            local cf = camera.CFrame
            camera.CFrame = cf * CFrame.Angles(0, math.rad(0.5), 0)
            task.wait(0.1)
            camera.CFrame = cf
        end)
        -- Virtual mouse click to reset idle timer
        pcall(function()
            VirtualUser:Button2Down(Vector2.new(0, 0), camera.CFrame)
            task.wait(0.1)
            VirtualUser:Button2Up(Vector2.new(0, 0), camera.CFrame)
        end)
        -- Virtual keypress (W) to simulate activity
        pcall(function()
            VirtualUser:KeyDown(0x57) -- W key
            task.wait(0.1)
            VirtualUser:KeyUp(0x57)
        end)
    end
end)
-- Inf Stamina (auto-on)
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
-- Always Daytime (auto-on)
task.spawn(function()
    local RunService = game:GetService("RunService")
    local Lighting   = game:GetService("Lighting")
    RunService.Heartbeat:Connect(function()
        Lighting.ClockTime = 12
    end)
end)
-- Auto Growth Loop (dual mode: grow new slots OR grow existing slots)
task.spawn(function()
    local Players       = game:GetService("Players")
    local RS            = game:GetService("ReplicatedStorage")
    local CoreGui       = game:GetService("CoreGui")
    local RunService    = game:GetService("RunService")
    local player        = Players.LocalPlayer

    -- ============================================================
    -- GAME CONFIG — detects which game we're in automatically
    -- ============================================================
    local GAME_CONFIGS = {
        [6174994284] = {
            name           = "SavannahLife",
            expectedAnimal = "Elephant",
            growSpawn      = Vector3.new(-6245.2, 10.0, 4664.3),
            warSpawn       = Vector3.new(-6245.2, 10.0, 4664.3),
            safePos        = Vector3.new(-6245.2, 10.0, 4664.3),
            dangerY        = -100,
            babySpawnArgs  = {
                Elephant = "Elephant",
                Lion     = "Lion",
                Giraffe  = "Giraffe",
                Hippo    = "Hippo",
                Rhino    = "Rhino",
                Impala   = "Impala",
            },
        },
        [18214855317] = {
            name           = "SavannahLife",
            expectedAnimal = "Elephant",   -- warns if a slot isn't an Elephant
            growSpawn      = Vector3.new(-6245.2, 10.0, 4664.3),
            warSpawn       = Vector3.new(-6245.2, 10.0, 4664.3),
            safePos        = Vector3.new(-6245.2, 10.0, 4664.3),
            dangerY        = -100,
            babySpawnArgs  = {
                Elephant = "Elephant",
                Lion     = "Lion",
                Giraffe  = "Giraffe",
                Hippo    = "Hippo",
                Rhino    = "Rhino",
                Impala   = "Impala",
            },
        },
        [9237322219] = {
            name           = "JungleLife",
            expectedAnimal = "Gorilla",    -- warns if a slot isn't a Gorilla
            growSpawn      = Vector3.new(1166.8350830078125, 24.75099754333496, -358.32073974609375),
            warSpawn       = Vector3.new(1166.8350830078125, 24.75099754333496, -358.32073974609375),
            safePos        = Vector3.new(1166.8350830078125, 24.75099754333496, -358.32073974609375),
            dangerY        = -100,
            babySpawnArgs  = {
                Gorilla  = "Gorilla",
            },
        },
    }

    -- Wait for character + AnimalName before locking in game config
    -- This fixes the issue where GameId doesn't match and character isn't loaded yet
    local function detectConfigByAnimal()
        local deadline = tick() + 15
        while tick() < deadline do
            local ch = player.Character
            if ch then
                local animal = ch:GetAttribute("AnimalName")
                if animal and animal ~= "" then
                    local JUNGLE_ANIMALS = { Gorilla=true, Chimpanzee=true, Leopard=true, Mandrill=true }
                    if JUNGLE_ANIMALS[animal] then
                        print("[GrowthLoop] Animal-detection: " .. animal .. " -> JungleLife")
                        return GAME_CONFIGS[9237322219]
                    end
                    local SAVANNAH_ANIMALS = { Elephant=true, Lion=true, Giraffe=true, Hippo=true, Rhino=true, Impala=true, Zebra=true, Cheetah=true, Hyena=true, Wildbeest=true }
                    if SAVANNAH_ANIMALS[animal] then
                        print("[GrowthLoop] Animal-detection: " .. animal .. " -> SavannahLife")
                        return GAME_CONFIGS[18214855317]
                    end
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
        warn("[GrowthLoop] GameId " .. tostring(game.GameId) .. " not recognised - waiting for character to detect by animal")
        gameConfig = detectConfigByAnimal()
        if not gameConfig then
            -- Detection failed — default to SavannahLife coords so it never TPs to 0,10,0
            -- Change this to JungleLife config if you're primarily using this on JL
            warn("[GrowthLoop] Detection failed - defaulting to SavannahLife config")
            gameConfig = GAME_CONFIGS[18214855317]
        end
    end
    shared._growthGameName = gameConfig.name
    print("[GrowthLoop] Detected game: " .. gameConfig.name)

    -- Mode flags (controlled by UI checkboxes via shared)
    local growNewSlots      = false
    local growExistingSlots = false

    -- Smart-mode state (used when BOTH checkboxes are ON)
    local MAX_SLOTS              = 40
    local slotsGrownThisCycle    = 0   -- counts only original existing slots grown
    local allExistingGrown       = false
    local parkingMode            = false  -- true = all 40 slots grown, just eat/drink on slot 1
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
    local pendingParkMode = false  -- set true if parking toggled before doParkOnSlotOne exists
    shared._setParkingMode = function(state)
        setParkingModeState(state)
        print("[GrowthLoop] Parking mode:", state)
        if state then
            pendingParkMode = true  -- picked up by a watcher once doParkOnSlotOne is ready
            if shared._runParkingMode then
                pendingParkMode = false
                task.spawn(shared._runParkingMode)
            end
        else
            pendingParkMode = false
        end
    end

    -- ============================================================
    -- EXISTING SLOTS — separate list per game, chosen automatically
    -- Saved characters are read live; no personal slot names are required.
    -- ============================================================
    local SAVANNAH_SLOTS = {}

    -- Legacy placeholder table kept empty; runtime switching uses SavedCharacters.
    local SAVANNAH_LION_SLOTS = {}

    local JUNGLE_SLOTS = {}

    -- Legacy placeholder table kept empty; runtime switching uses SavedCharacters.
    local JUNGLE_TIGER_SLOTS = {}

    -- These legacy placeholders stay empty. Runtime switching uses SavedCharacters.
    local existingSlots = {}
    local originalSlotCount = 0
    local trackedSlots = {}
    local trackedSlotLookup = {}

    local function findSlotIndexByName(name, pool)
        if not name then
            return nil
        end

        pool = pool or trackedSlots

        for i, v in ipairs(pool) do
            if v == name then
                return i
            end
        end

        return nil
    end

    local function getTrackedSlotTotal()
        return math.min(#trackedSlots, MAX_SLOTS)
    end

    local function trackSlotName(name)
        if not name then
            return false
        end

        if trackedSlotLookup[name] then
            return false
        end

        if #trackedSlots >= MAX_SLOTS then
            warn("[GrowthLoop] Tracked slot list already at max capacity — skipping add for:", name)
            return false
        end

        table.insert(trackedSlots, name)
        trackedSlotLookup[name] = true
        return true
    end

    -- Legacy helper left in place, but the runtime SavedCharacters flow overrides it.
    local function pickSlotListForAnimal(animal)
        if gameConfig.name == "JungleLife" then
            if (animal == "Lion" or animal == "Tiger") and #JUNGLE_TIGER_SLOTS > 0 then
                return JUNGLE_TIGER_SLOTS
            end
            return JUNGLE_SLOTS
        else
            if (animal == "Lion" or animal == "Tiger") and #SAVANNAH_LION_SLOTS > 0 then
                return SAVANNAH_LION_SLOTS
            end
            return SAVANNAH_SLOTS
        end
    end

    -- Runtime sync handles empty-slot warnings after SavedCharacters has loaded.

    local existingSlotIndex = 1

    -- Per-pool index tracker for animal-specific existing slot cycling.
    -- Keyed by pool reference (the table itself), so each slot list advances independently.
    local poolIndexes = {}
    local function getPoolIndex(pool)
        return poolIndexes[pool] or 1
    end
    local function advancePoolIndex(pool)
        local cur = getPoolIndex(pool)
        poolIndexes[pool] = (cur % #pool) + 1
    end

    -- ============================================================
    -- NEW SLOTS name pool — uses the same slot names as existingSlots, in order
    -- This guarantees the names are real working slots
    -- ============================================================
    local namePool = (gameConfig.name == "JungleLife") and JUNGLE_SLOTS or SAVANNAH_SLOTS
    local newSlotIndex = 1  -- sequential pointer, no randomness

    local function getUniqueName(animal)
        -- If animal is Lion/Tiger and a lion pool exists, use it
        local pool = namePool
        if animal then
            local animalPool = pickSlotListForAnimal(animal)
            if animalPool and #animalPool > 0 then
                pool = animalPool
            end
        end
        local name = pool[((newSlotIndex - 1) % #pool) + 1]
        newSlotIndex = newSlotIndex + 1
        return name
    end

    local function removeName(name)
        -- No-op: sequential pool doesn't track used names
    end

    -- Runtime slot source of truth: live SavedCharacters order keyed by CharacterName.
    do
        local ALLOWED_EXISTING_ANIMALS_BY_GAME = {
            SavannahLife = {
                Elephant = true,
                Lion = true,
                Giraffe = true,
                Hippo = true,
                Rhino = true,
                Impala = true,
                Zebra = true,
                Cheetah = true,
                Hyena = true,
                Wildbeest = true,
            },
            JungleLife = {
                Gorilla = true,
                Chimpanzee = true,
                Leopard = true,
                Mandrill = true,
                Tiger = true,
                Lion = true,
            },
        }

        local savedSlotRecords = {}
        local lastSavedCharacterRefresh = 0
        local SAVE_REFRESH_INTERVAL = 1
        local warnedMissingSavedCharactersAPI = false
        local warnedSavedCharactersReadFailed = false

        existingSlots = {}
        originalSlotCount = 0
        trackedSlots = {}
        trackedSlotLookup = {}
        existingSlotIndex = 1

        local function isPlayerDataReplication(candidate)
            return type(candidate) == "table" and type(candidate.GetKeyData) == "function"
        end

        local function resolvePlayerDataReplication()
            local cached = shared._playerDataReplication
            if isPlayerDataReplication(cached) then
                return cached
            end

            local directCandidates = {
                shared.PlayerDataReplication,
                _G.PlayerDataReplication,
            }

            if type(getgenv) == "function" then
                local ok, env = pcall(getgenv)
                if ok and type(env) == "table" then
                    table.insert(directCandidates, env.PlayerDataReplication)
                end
            end

            for _, candidate in ipairs(directCandidates) do
                if isPlayerDataReplication(candidate) then
                    shared._playerDataReplication = candidate
                    return candidate
                end
            end

            local searchRoots = {
                RS,
                player:FindFirstChild("PlayerScripts"),
                player:FindFirstChild("PlayerGui"),
            }

            for _, root in ipairs(searchRoots) do
                if root then
                    local moduleScript = root:FindFirstChild("PlayerDataReplication", true)
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
            if typeof(cached) == "Instance" and cached.Parent then
                return cached
            end

            local playerGui = player:FindFirstChildOfClass("PlayerGui")
            local menu = (playerGui and playerGui:FindFirstChild("SavedCharactersMenu", true))
                or CoreGui:FindFirstChild("SavedCharactersMenu", true)

            if menu then
                shared._savedCharactersMenu = menu
            end

            return menu
        end

        local function setSelectedSavedCharacterName(name)
            if type(name) ~= "string" or name == "" then
                return
            end

            local menu = findSavedCharactersMenu()
            if menu then
                pcall(function()
                    menu:SetAttribute("UniqueCharacterName", name)
                end)
            end
        end

        local function rebuildTrackedFromRecords(records)
            trackedSlots = {}
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
                    warn("[GrowthLoop] PlayerDataReplication was not found - keeping last saved slot snapshot")
                end
                return savedSlotRecords
            end

            local ok, rawList = pcall(function()
                return replication.GetKeyData("SavedCharacters")
            end)

            if not ok or type(rawList) ~= "table" then
                if not warnedSavedCharactersReadFailed then
                    warnedSavedCharactersReadFailed = true
                    warn("[GrowthLoop] Failed to read SavedCharacters - keeping last saved slot snapshot")
                end
                return savedSlotRecords
            end

            warnedSavedCharactersReadFailed = false
            local allowedAnimals = ALLOWED_EXISTING_ANIMALS_BY_GAME[gameConfig.name]
            local nextRecords = {}
            local nextNames = {}
            local seen = {}

            for _, entry in ipairs(rawList) do
                if type(entry) == "table" then
                    local charName = entry.CharacterName
                    local animalName = entry.AnimalName
                    if type(charName) == "string"
                        and charName ~= ""
                        and type(animalName) == "string"
                        and animalName ~= ""
                        and (not allowedAnimals or allowedAnimals[animalName])
                        and not seen[charName]
                    then
                        table.insert(nextRecords, entry)
                        table.insert(nextNames, charName)
                        seen[charName] = true
                        if #nextRecords >= MAX_SLOTS then
                            break
                        end
                    end
                end
            end

            savedSlotRecords = nextRecords
            existingSlots = nextNames
            rebuildTrackedFromRecords(nextRecords)

            if #existingSlots == 0 or existingSlotIndex > #existingSlots then
                existingSlotIndex = 1
            end

            if originalSlotCount == 0 and #existingSlots > 0 then
                originalSlotCount = #existingSlots
            end

            return savedSlotRecords
        end

        local function findSavedCharacterRecordByName(name, records)
            if type(name) ~= "string" or name == "" then
                return nil
            end

            records = records or syncSavedCharacterRecords()
            for _, entry in ipairs(records) do
                if entry.CharacterName == name then
                    return entry
                end
            end

            return nil
        end

        local function getFirstExistingSlotRecord()
            local records = syncSavedCharacterRecords(true)
            return records[1]
        end

        local function getNextExistingSlotRecord()
            local records = syncSavedCharacterRecords(true)
            if #records == 0 then
                return nil, nil, 0
            end

            local idx
            local currentIdx = findSlotIndexByName(shared._currentGrowthName, existingSlots)
            if currentIdx then
                idx = (currentIdx % #records) + 1
            else
                if existingSlotIndex < 1 or existingSlotIndex > #records then
                    existingSlotIndex = 1
                end
                idx = existingSlotIndex
            end

            local entry = records[idx]
            existingSlotIndex = (idx % #records) + 1
            return entry, idx, #records
        end

        local function sanitizeNameSeed(text)
            text = tostring(text or ""):gsub("[^%w]+", "")
            if text == "" then
                text = "Slot"
            end
            return string.sub(text, 1, 18)
        end

        findSlotIndexByName = function(name, pool)
            if not name then
                return nil
            end

            pool = pool or trackedSlots

            for i, value in ipairs(pool) do
                if value == name then
                    return i
                end
            end

            return nil
        end

        getTrackedSlotTotal = function()
            syncSavedCharacterRecords()
            return math.min(#trackedSlots, MAX_SLOTS)
        end

        trackSlotName = function(name)
            if not name or trackedSlotLookup[name] then
                return false
            end

            if #trackedSlots >= MAX_SLOTS then
                warn("[GrowthLoop] Tracked slot list already at max capacity - skipping add for:", name)
                return false
            end

            table.insert(trackedSlots, name)
            trackedSlotLookup[name] = true
            return true
        end

        local newSlotNamePool = {
            "Jack",
            "John",
            "Evian",
            "Aiman",
            "Adam",
            "Alex",
            "Ben",
            "Sam",
            "Max",
            "Leo",
            "Noah",
            "Liam",
            "Omar",
            "Zain",
            "Ali",
            "Ryan",
            "Ethan",
            "Mason",
            "Dylan",
            "Lucas",
            "Harry",
            "Jacob",
            "Henry",
            "Isaac",
            "Yusuf",
            "Amir",
            "Rehan",
            "Arman",
            "Daniel",
            "David",
            "Aaron",
            "Oscar",
            "Toby",
            "Kian",
            "Kai",
            "Jay",
            "Sean",
            "Chris",
            "Kevin",
            "Mark",
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
                    if not usedNames[candidate] then
                        return candidate
                    end
                end
            end

            local base = sanitizeNameSeed(shared._currentGrowthName or animal or gameConfig.expectedAnimal or "Slot")
            for i = 1, 999 do
                local candidate = string.format("%s%d", base, i)
                if not usedNames[candidate] then
                    return candidate
                end
            end

            return string.format("%s%d", base, math.floor(os.clock() * 1000))
        end

        removeName = function(name)
            return nil
        end

        shared._syncSavedCharacterRecords = syncSavedCharacterRecords
        shared._findSavedCharacterRecordByName = findSavedCharacterRecordByName
        shared._getFirstExistingSlotRecord = getFirstExistingSlotRecord
        shared._getNextExistingSlotRecord = getNextExistingSlotRecord
        shared._setSelectedSavedCharacterName = setSelectedSavedCharacterName

        syncSavedCharacterRecords(true)
        if originalSlotCount == 0 then
            warn("[GrowthLoop] WARNING: SavedCharacters returned no valid slots for", gameConfig.name)
        end
    end

    -- ============================================================
    -- LOCK
    -- ============================================================
    local isLooping = false
    local loopToken = 0

    local function forceUnlockGrowthLoop(reason)
        loopToken = loopToken + 1
        isLooping = false
        shared._inGrowthReset = false
        warn("[GrowthLoop] Force-unlocked growth loop: " .. tostring(reason))
    end

    local function withLock(fn)
        if isLooping then return false end
        isLooping = true
        loopToken = loopToken + 1
        local myToken = loopToken
        shared._inGrowthReset = true  -- block auto drink/eat from interfering
        local ok, err = pcall(fn)
        if loopToken == myToken then
            shared._inGrowthReset = false
            isLooping = false
        end
        if not ok then warn("[GrowthLoop] Error:", err) end
        return ok
    end

    -- ============================================================
    -- TRACKING
    -- ============================================================
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

    -- Reads animal, gender, skin directly from the character attributes
    -- so we never have to hardcode or assume anything
    local function getSlotInfo(character)
        local animal = character:GetAttribute("AnimalName") or currentAnimalName or "Elephant"
        local gender = character:GetAttribute("Gender")     or currentGender or "Female"
        local skin   = character:GetAttribute("Skin")       or currentSkin or "Default"
        return animal, gender, skin
    end

    local function extractMotherName(result)
        if type(result) == "string" and result ~= "" then
            return result
        end

        if type(result) ~= "table" then
            return nil
        end

        for _, value in ipairs(result) do
            if type(value) == "string" and value ~= "" then
                return value
            end
            if type(value) == "table" then
                local name = value.PlayerName or value.Name or value.DisplayName or value.UserName or value.Username
                if type(name) == "string" and name ~= "" then
                    return name
                end
            end
        end

        for _, value in pairs(result) do
            if type(value) == "string" and value ~= "" then
                return value
            end
            if type(value) == "table" then
                local name = value.PlayerName or value.Name or value.DisplayName or value.UserName or value.Username
                if type(name) == "string" and name ~= "" then
                    return name
                end
            end
        end

        return nil
    end

    local function isBabySavedCharacter(entry)
        if type(entry) ~= "table" then
            return false
        end

        local growth = entry.GrowthPercentage
        return type(growth) == "number" and growth <= 0.01
    end

    local function requestBabyMotherName(entry)
        local remote = RS:FindFirstChild("BabySpawnsRequestMotherNamesRemoteFunction")
        if not remote or type(entry) ~= "table" then
            return nil
        end

        local animal = entry.AnimalName
        if type(animal) ~= "string" or animal == "" then
            return nil
        end

        local requestArg = gameConfig.babySpawnArgs[animal] or animal
        local ok, result = pcall(function()
            return remote:InvokeServer(requestArg)
        end)

        if not ok then
            warn("[GrowthLoop] Baby mother request failed for:", animal)
            return nil
        end

        local motherName = extractMotherName(result)
        if motherName then
            print("[GrowthLoop] Baby mother selected for", entry.CharacterName, ":", motherName)
        else
            warn("[GrowthLoop] No baby mother name returned for:", entry.CharacterName)
        end

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
            print("[GrowthLoop] Now tracking:", currentGrowthName,
                  "| Animal:", currentAnimalName,
                  "| Gender:", currentGender)
        else
            warn("[GrowthLoop] Timed out waiting for CharacterName")
        end
    end

    -- ============================================================
    -- SPAWN + SETUP (used by both modes)
    -- ============================================================
    local function spawnAndSetup(slotEntryOrName)
        local syncSavedCharacterRecords = shared._syncSavedCharacterRecords
        local findSavedCharacterRecordByName = shared._findSavedCharacterRecordByName
        local setSelectedSavedCharacterName = shared._setSelectedSavedCharacterName

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
            warn("[GrowthLoop] spawnAndSetup called without a valid CharacterName")
            return false
        end

        if type(entry) ~= "table" then
            entry = {
                CharacterName = charName,
            }
        end

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
        if not spawnOk then
            warn("[GrowthLoop] SpawnAsCharacter failed:", spawnErr)
            return false
        end
        local waited = 0
        local spawned = false
        while waited < 10 do
            task.wait(0.2)
            waited = waited + 0.2
            local ch = player.Character
            if ch and ch:FindFirstChild("HumanoidRootPart") then
                spawned = true
                break
            end
        end
        if not spawned then
            warn("[GrowthLoop] HumanoidRootPart never appeared for:", charName)
            return false
        end
        trackSlotName(charName)
        if type(syncSavedCharacterRecords) == "function" then
            syncSavedCharacterRecords(true)
        end
        -- Food type depends on the animal, not just the game
        -- Spy on SetFoodTypeRemoteEvent while eating as each animal to confirm these strings
        local FOOD_TYPE_BY_ANIMAL = {
            Elephant   = "Grass",
            Lion       = "Meat",
            Giraffe    = "Grass",
            Hippo      = "Grass",
            Rhino      = "Grass",
            Gorilla    = "Grass",
            Crocodile  = "Meat",
        }
        local ch = player.Character
        local animal = ch and ch:GetAttribute("AnimalName") or "Elephant"
        local foodType = FOOD_TYPE_BY_ANIMAL[animal] or "Grass"
        pcall(function()
            RS.AnimalGameFrameworkShared.Utils.CanEatDrink.SetFoodTypeRemoteEvent:FireServer(foodType)
            print("[GrowthLoop] Set food type:", foodType, "for:", animal)
        end)
        task.wait(0.5)
        pcall(function()
            RS.SaveCharacterStatsRemoteEvent:FireServer(charName, "Oxygen", 100)
            RS.SaveCharacterStatsRemoteEvent:FireServer(charName, "Stamina", 100)
        end)
        return true
    end

    -- ============================================================
    -- TELEPORT + EAT/DRINK ENABLE (used by both modes)
    -- Uses gameConfig.growSpawn so coords are automatic per game
    -- Verifies animal matches expected for this game
    -- Checks Y position to avoid being underwater after spawn
    -- ============================================================
    local function safeTP(character, targetPos)
        local root = character:FindFirstChild("HumanoidRootPart")
        local hum  = character:FindFirstChild("Humanoid")
        if not root or not hum then return false end

        -- Anchor FIRST so physics can't drag the character underwater mid-teleport
        root.Anchored = true
        hum:ChangeState(Enum.HumanoidStateType.Physics)

        -- Bump Y by +3 so we land cleanly above the terrain surface
        local safeTarget = Vector3.new(targetPos.X, targetPos.Y + 3, targetPos.Z)

        local attempts = 0
        repeat
            attempts = attempts + 1
            -- Fire the CFrame repeatedly while anchored — position will actually stick
            for _ = 1, 30 do
                local r = character:FindFirstChild("HumanoidRootPart")
                if r then
                    r.CFrame = CFrame.new(safeTarget)
                end
                task.wait()
            end
            task.wait(0.3)

            local currentRoot = character:FindFirstChild("HumanoidRootPart")
            if currentRoot then
                local yPos = currentRoot.Position.Y
                if yPos >= (targetPos.Y - 2) then
                    print("[GrowthLoop] TP confirmed at Y:", yPos)
                    break
                else
                    warn("[GrowthLoop] TP still off at Y:", yPos, "— retrying (attempt", attempts, ")")
                end
            end
        until attempts >= 5

        task.wait(0.5)
        -- Unanchor AFTER position is confirmed
        local finalRoot = character:FindFirstChild("HumanoidRootPart")
        if finalRoot then finalRoot.Anchored = false end
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        for _ = 1, 10 do
            character:SetAttribute("MovementDisabled", false)
            task.wait(0.1)
        end
        return true
    end

    local WAR_SPAWN    = gameConfig.warSpawn
    local GROW_SPAWN   = gameConfig.growSpawn
    local TP_TOLERANCE = 12  -- studs: how close we need to be to consider TP successful
    shared._growSpawn  = GROW_SPAWN  -- expose so carcass eat can TP back

    -- Teleport to a target and keep retrying until confirmed within TP_TOLERANCE studs
    -- Uses unanchored SetPrimaryPartCFrame for both SL and JL
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
                for _ = 1, 10 do
                    character:SetAttribute("MovementDisabled", false)
                    task.wait(0.1)
                end

                -- Verify position
                local r = character:FindFirstChild("HumanoidRootPart")
                if r then
                    local dist = (r.Position - targetPos).Magnitude
                    print(string.format("[GrowthLoop] [%s] TP attempt %d — dist: %.1f studs", label, attempt, dist))
                    if dist <= TP_TOLERANCE then
                        print("[GrowthLoop] [" .. label .. "] TP confirmed on attempt " .. attempt)
                        return true
                    else
                        warn("[GrowthLoop] [" .. label .. "] Too far (" .. string.format("%.1f", dist) .. " studs) — retrying")
                    end
                end
            end
        end
        warn("[GrowthLoop] [" .. label .. "] Failed after " .. maxAttempts .. " attempts — continuing anyway")
        return false
    end

    local function teleportAndEnable(newChar, charName)
        -- Wait for the correct character to be loaded
        local charWait = 0
        while charWait < 15 do
            task.wait(0.2)
            charWait = charWait + 0.2
            local ch = player.Character
            if ch and ch:FindFirstChild("HumanoidRootPart") then
                local cname = ch:GetAttribute("CharacterName")
                if cname == charName then
                    newChar = ch
                    break
                elseif charWait >= 5 and cname ~= nil then
                    warn("[GrowthLoop] Name mismatch expected", charName, "got", cname, "— proceeding")
                    newChar = ch
                    break
                elseif charWait >= 8 then
                    warn("[GrowthLoop] CharacterName never loaded, proceeding")
                    newChar = ch
                    break
                end
            end
        end

        if not newChar then
            warn("[GrowthLoop] Character never appeared, skipping TP")
            return
        end

        task.wait(1.5)
        local ch = player.Character
        if ch then newChar = ch end

        -- Read animal/gender AFTER spawn so we always have fresh info
        local animal, gender, skin = getSlotInfo(newChar)
        currentAnimalName = animal
        currentGender     = gender
        currentSkin       = skin
        print("[GrowthLoop] Slot info — Animal:", animal, "| Gender:", gender, "| Skin:", skin)

        -- Verify this slot's animal matches what this game expects
        -- e.g. Jungle Life expects Gorilla, Savannah Life expects Elephant
        -- If it doesn't match, we still grow it (it's your slot), just warn you
        local expectedAnimal = gameConfig.expectedAnimal
        if expectedAnimal and animal ~= expectedAnimal then
            warn("[GrowthLoop] WARNING: Expected", expectedAnimal, "but this slot is", animal,
                 "— growing anyway, but check your slots")
        end

        -- Confirmed TP to grow spawn — retries until within TP_TOLERANCE studs
        print("[GrowthLoop] Teleporting to grow spawn for " .. gameConfig.name .. " | Animal: " .. animal .. " | Gender: " .. gender)
        confirmedTP(newChar, GROW_SPAWN, "GrowSpawn")

        -- Wait 7s for character to fully settle
        print("[GrowthLoop] Waiting 7s for character to settle...")
        task.wait(7)

        -- OFF -> ON -> OFF -> ON  (double-cycle clears any stuck state)
        -- For carnivores: toggle auto eat CARCASS instead of auto eat grass
        local ch2 = player.Character
        local isCarnivore = false
        if ch2 then
            local an = ch2:GetAttribute("AnimalName") or ""
            local CARNIVORES = { Lion=true, Tiger=true, Cheetah=true, Crocodile=true, Leopard=true }
            isCarnivore = CARNIVORES[an] == true
        end

        local function toggleEatDrink(state, label)
            if not isCarnivore then
                if shared._autoEatChecked then shared._autoEatChecked(state) end
            else
                -- Carnivores: toggle auto eat CARCASS instead of auto eat grass
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

    -- ============================================================
    -- TELEPORT TO WAR SPAWN (called when 100% grown, before reset)
    -- Uses gameConfig.warSpawn so coords are automatic per game
    -- ============================================================
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

    -- ============================================================
    -- RESET TO MENU
    -- ============================================================
    local function resetToMenu()
        pcall(function()
            RS.CustomCharacterResetRemoteFunction:InvokeServer()
        end)
        task.wait(2)
    end

    -- ============================================================
    -- GROW NEW SLOTS MODE
    -- ============================================================
    local function doGrowthReset()
        withLock(function()
            -- Kill auto eat/drink immediately so they don't fight the TP
            if shared._autoEatChecked then shared._autoEatChecked(false) end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end
            print("[GrowthLoop] Auto eat/drink OFF — starting growth reset")

            local character = player.Character
            if not character then return end

            -- Read animal/gender/skin from the ACTUAL character attributes
            -- so it works for Gorilla, Elephant, Male, Female — anything
            local animalName, gender, skin = getSlotInfo(character)
            local newName = getUniqueName(animalName)

            print("[GrowthLoop] Full grown! Creating new slot:", newName,
                  "| Animal:", animalName, "| Gender:", gender)

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

            local spawnOk = spawnAndSetup({
                CharacterName = newName,
                AnimalName = animalName,
                GrowthPercentage = 0,
            })
            if not spawnOk then
                warn("[GrowthLoop] Spawn failed:", newName)
                removeName(newName)
                return
            end

            teleportAndEnable(nil, newName)

            currentGrowthName = newName
            shared._currentGrowthName = newName
            currentAnimalName = animalName
            currentGender     = gender
            currentSkin       = skin

            -- Track this new slot only once and never beyond the hard max.
            local added = trackSlotName(newName)
            print("[GrowthLoop] Now growing:", newName, "| Total slots:", getTrackedSlotTotal(), "| Added:", added)
        end)
    end

    -- ============================================================
    -- GROW EXISTING SLOTS MODE
    -- ============================================================
    local function doExistingSlotCycle()
        withLock(function()
            -- Kill auto eat/drink immediately so they don't fight the TP
            if shared._autoEatChecked then shared._autoEatChecked(false) end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end
            print("[GrowthLoop] Auto eat/drink OFF — starting slot cycle")

            -- Pick the pool based on the CURRENT animal we're growing.
            -- This way Lion cycles through SAVANNAH_LION_SLOTS / JUNGLE_TIGER_SLOTS,
            -- while Elephant/Gorilla/Impala cycle through the main pool.
            local curCh = player.Character
            local curAnimal = (curCh and curCh:GetAttribute("AnimalName")) or currentAnimalName or ""
            local pool = pickSlotListForAnimal(curAnimal)

            -- Guard: if pool is empty do nothing
            if not pool or #pool == 0 then
                warn("[GrowthLoop] [Existing] SavedCharacters has no valid slots for", gameConfig.name,
                     "animal:", curAnimal)
                return
            end

            local idx = getPoolIndex(pool)
            local slotName = pool[idx]
            print("[GrowthLoop] [Existing] [" .. curAnimal .. "] Moving to slot",
                  idx, "/", #pool, ":", slotName)

            -- Advance index BEFORE any async work so a crash/skip still moves forward
            advancePoolIndex(pool)
            -- Keep legacy existingSlotIndex in sync for any other code that reads it
            existingSlotIndex = getPoolIndex(pool)

            teleportToWarSpawn()
            resetToMenu()

            local spawnOk = spawnAndSetup(slotName)
            if not spawnOk then
                warn("[GrowthLoop] [Existing] Failed to spawn:", slotName)
                return
            end

            -- Check if this slot is already at 100% — if so, skip it immediately
            task.wait(1)
            local ch = player.Character
            if ch then
                local growth = waitForAttribute(ch, "GrowthPercentage", 8)
                if growth and growth >= 1 then
                    print("[GrowthLoop] [Existing] Slot", slotName, "already 100%, skipping")
                    return
                end

                -- Read animal/gender from THIS slot's actual attributes
                local animal, gender, skin = getSlotInfo(ch)
                print("[GrowthLoop] [Existing] Slot:", slotName,
                      "| Animal:", animal, "| Gender:", gender)

            end

            teleportAndEnable(nil, slotName)

            currentGrowthName = slotName
            shared._currentGrowthName = slotName
            print("[GrowthLoop] [Existing] Now growing:", slotName)
        end)
    end

    -- ============================================================
    -- PARK ON SLOT 1 — all 40 slots grown, sit and earn passive coins
    -- ============================================================
    local function doParkOnSlotOne()
        local slotOne = existingSlots[1]
        if not slotOne then
            warn("[GrowthLoop] [Park] existingSlots[1] is nil — cannot park")
            return
        end

        withLock(function()
            -- Check current slot growth — if not 100%, grow existing first
            local ch = player.Character
            local growth = ch and ch:GetAttribute("GrowthPercentage")
            if growth and growth < 1 then
                print(string.format("[GrowthLoop] [Park] Current slot not full (%.0f%%) — growing existing first", growth * 100))
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
                spawnOk = spawnAndSetup(slotOne)
                if spawnOk then break end
                warn("[GrowthLoop] [Park] Spawn attempt " .. attempt .. " failed — retrying")
                task.wait(2)
            end

            if not spawnOk then
                warn("[GrowthLoop] [Park] All spawn attempts failed — watchdog will retry")
                return
            end

            teleportAndEnable(nil, slotOne)
            currentGrowthName = slotOne
            shared._currentGrowthName = slotOne
            print("[GrowthLoop] [Park] Parked on " .. slotOne .. " — passive coins active")
        end)
    end
    doExistingSlotCycle = function()
        withLock(function()
            if shared._autoEatChecked then shared._autoEatChecked(false) end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end
            print("[GrowthLoop] Auto eat/drink OFF - starting slot cycle")

            local getNextExistingSlotRecord = shared._getNextExistingSlotRecord
            local entry, idx, total = type(getNextExistingSlotRecord) == "function"
                and getNextExistingSlotRecord()
                or nil

            if not entry then
                warn("[GrowthLoop] [Existing] SavedCharacters has no valid slots for", gameConfig.name)
                return
            end

            local slotName = entry.CharacterName
            print("[GrowthLoop] [Existing] Moving to slot",
                  idx, "/", total, ":", slotName, "| Animal:", tostring(entry.AnimalName))

            teleportToWarSpawn()
            resetToMenu()

            local spawnOk = spawnAndSetup(entry)
            if not spawnOk then
                warn("[GrowthLoop] [Existing] Failed to spawn:", slotName)
                return
            end

            task.wait(1)
            local ch = player.Character
            if ch then
                local growth = waitForAttribute(ch, "GrowthPercentage", 8)
                if growth and growth >= 1 then
                    print("[GrowthLoop] [Existing] Slot", slotName, "already 100%, skipping")
                    return
                end

                local animal, gender = getSlotInfo(ch)
                print("[GrowthLoop] [Existing] Slot:", slotName,
                      "| Animal:", animal, "| Gender:", gender)
            end

            teleportAndEnable(nil, slotName)

            currentGrowthName = slotName
            shared._currentGrowthName = slotName
            print("[GrowthLoop] [Existing] Now growing:", slotName)
        end)
    end

    doParkOnSlotOne = function()
        local getFirstExistingSlotRecord = shared._getFirstExistingSlotRecord
        local slotOneEntry = type(getFirstExistingSlotRecord) == "function"
            and getFirstExistingSlotRecord()
            or nil
        local slotOne = slotOneEntry and slotOneEntry.CharacterName
        if not slotOne then
            warn("[GrowthLoop] [Park] existingSlots[1] is nil - cannot park")
            return
        end

        withLock(function()
            local ch = player.Character
            local growth = ch and ch:GetAttribute("GrowthPercentage")
            if growth and growth < 1 then
                print(string.format("[GrowthLoop] [Park] Current slot not full (%.0f%%) - growing existing first", growth * 100))
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
                warn("[GrowthLoop] [Park] Spawn attempt " .. attempt .. " failed - retrying")
                task.wait(2)
            end

            if not spawnOk then
                warn("[GrowthLoop] [Park] All spawn attempts failed - watchdog will retry")
                return
            end

            teleportAndEnable(nil, slotOne)
            currentGrowthName = slotOne
            shared._currentGrowthName = slotOne
            print("[GrowthLoop] [Park] Parked on " .. slotOne .. " - passive coins active")
        end)
    end

    shared._runParkingMode = doParkOnSlotOne

    -- Pick up pendingParkMode now that doParkOnSlotOne is defined
    if pendingParkMode then
        pendingParkMode = false
        task.spawn(function() doParkOnSlotOne() end)
    end

    -- ============================================================
    -- DEATH RECOVERY
    -- ============================================================
    local function doDeathRecovery()
        if not currentGrowthName then return end
        withLock(function()
            if parkingMode then
                -- In parking mode, always recover to slot 1, never anything else
                print("[GrowthLoop] Death in parking mode — recovering slot 1")
                task.wait(2)
                task.spawn(doParkOnSlotOne)
                return
            end
            print("[GrowthLoop] Death detected! Returning to:", currentGrowthName)
            task.wait(2)
            local ok = spawnAndSetup(currentGrowthName)
            if not ok then
                warn("[GrowthLoop] Death recovery failed for:", currentGrowthName)
            end
        end)
    end

    -- ============================================================
    -- STARTUP
    -- ============================================================
    task.spawn(trackCurrentCharacter)

    local lastGrowth = 0
    local growthCheckReady = false

    local function armGrowthCheck(character)
        growthCheckReady = false
        lastGrowth = 0
        task.spawn(function()
            local val = waitForAttribute(character, "GrowthPercentage", 15)
            if val ~= nil then
                -- If the slot is already at 100% on spawn, set lastGrowth to 0
                -- so we don't immediately false-fire the reset
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

    -- ============================================================
    -- HEARTBEAT — detects 100% and death
    -- ============================================================
    RunService.Heartbeat:Connect(function()
        if isLooping then return end
        if not growthCheckReady then return end
        if shared._inCarcassEat then return end  -- block war TP while carcass eat is mid-cycle
        local character = player.Character
        if not character then return end

        local growth = character:GetAttribute("GrowthPercentage")
        if not growth then return end

        -- 100% grown
        if growth >= 1 and lastGrowth >= 0.9 then
            local bothOn = growExistingSlots and growNewSlots

            if parkingMode then
                -- All 40 slots fully grown — just sit on slot 1 and eat/drink, do nothing
                return
            end

            if bothOn then
                -- SMART MODE: grow existing first, then create new, then park
                if not allExistingGrown then
                    -- Still cycling through the ORIGINAL slots (snapshot taken at startup)
                    slotsGrownThisCycle = slotsGrownThisCycle + 1
                    print("[GrowthLoop] [Smart] Original slot grown: " .. slotsGrownThisCycle .. " / " .. originalSlotCount)
                    if slotsGrownThisCycle >= originalSlotCount then
                        allExistingGrown = true
                        slotsGrownThisCycle = 0
                        print("[GrowthLoop] [Smart] All " .. originalSlotCount .. " original slots grown — now creating new slots")
                    end
                    task.spawn(doExistingSlotCycle)
                elseif getTrackedSlotTotal() < MAX_SLOTS then
                    -- Create new slots until total reaches 40
                    print("[GrowthLoop] [Smart] Creating new slot (" .. getTrackedSlotTotal() .. "/" .. MAX_SLOTS .. ")")
                    task.spawn(doGrowthReset)
                else
                    -- All 40 slots exist and grown — park on slot 1
                    setParkingModeState(true)
                    print("[GrowthLoop] [Smart] All " .. MAX_SLOTS .. " slots grown — parking on slot 1 for passive coins")
                    task.spawn(doParkOnSlotOne)
                end
            elseif growExistingSlots then
                task.spawn(doExistingSlotCycle)
            elseif growNewSlots then
                task.spawn(doGrowthReset)
            end
            return
        end

        -- Death detection
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

    -- ============================================================
    -- HUD — compact slot counter, top-right
    -- ============================================================
    local hudGui = Instance.new("ScreenGui")
    hudGui.Name = "GrowthLoopHUD"
    hudGui.ResetOnSpawn = false
    hudGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    hudGui.Parent = game:GetService("CoreGui")

    local CARD_W, CARD_H = 190, 68
    local hudFrame = Instance.new("Frame")
    hudFrame.Size = UDim2.new(0, CARD_W, 0, CARD_H)
    hudFrame.Position = UDim2.new(1, -(CARD_W + 8), 0, 8)
    hudFrame.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
    hudFrame.BackgroundTransparency = 0.15
    hudFrame.BorderSizePixel = 0
    hudFrame.Parent = hudGui
    Instance.new("UICorner", hudFrame).CornerRadius = UDim.new(0, 8)

    -- left accent bar
    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 3, 1, -14)
    accent.Position = UDim2.new(0, 0, 0, 7)
    accent.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
    accent.BorderSizePixel = 0
    accent.Parent = hudFrame
    Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)

    local function lbl(y, sz, bold)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -16, 0, sz + 2)
        l.Position = UDim2.new(0, 12, 0, y)
        l.BackgroundTransparency = 1
        l.TextColor3 = Color3.fromRGB(230, 230, 230)
        l.TextSize = sz
        l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.Parent = hudFrame
        return l
    end

    local lblSlot   = lbl(6,  12, true)   -- "Muj [2/40]"
    local lblGrowth = lbl(22, 11, false)  -- "Growth: 73%"
    local lblBar    = lbl(36, 9,  false)  -- progress bar
    local lblMode   = lbl(51, 9,  false)  -- mode
    lblBar.Font = Enum.Font.Code

    -- green progress bar frame
    local barBg = Instance.new("Frame")
    barBg.Size = UDim2.new(1, -26, 0, 5)
    barBg.Position = UDim2.new(0, 12, 0, 36)
    barBg.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    barBg.BorderSizePixel = 0
    barBg.Parent = hudFrame
    Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

    local barFill = Instance.new("Frame")
    barFill.Size = UDim2.new(0, 0, 1, 0)
    barFill.BackgroundColor3 = Color3.fromRGB(80, 210, 100)
    barFill.BorderSizePixel = 0
    barFill.Parent = barBg
    Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)
    -- hide the text bar label, we use the frame bar instead
    lblBar.Text = ""

    task.spawn(function()
        while true do
            task.wait(0.5)
            local ch = player.Character
            local growth = ch and ch:GetAttribute("GrowthPercentage") or 0
            local slotName = currentGrowthName or "—"
            local growthPct = math.floor(growth * 100)

            local trackedTotal = getTrackedSlotTotal()
            local slotIdx = findSlotIndexByName(currentGrowthName) or 0
            if trackedTotal > 0 then
                slotIdx = math.clamp(slotIdx, 0, trackedTotal)
            else
                slotIdx = 0
            end
            lblSlot.Text = string.format("%s  [%d/%d]", slotName, slotIdx, trackedTotal)

            lblGrowth.Text = string.format("Growth: %d%%", growthPct)
            -- colour red->yellow->green
            local pct = math.clamp(growth, 0, 1)
            if pct < 0.5 then
                lblGrowth.TextColor3 = Color3.fromRGB(255, math.floor(pct * 2 * 200), 60)
            else
                lblGrowth.TextColor3 = Color3.fromRGB(math.floor((1-pct)*2*255), 210, 60)
            end

            -- green fill bar
            barFill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)

            -- mode label + accent colour
            local mode, col
            if parkingMode then
                mode = "* passive coins"
                col = Color3.fromRGB(255, 200, 50)
            elseif growExistingSlots and growNewSlots then
                col = Color3.fromRGB(100, 180, 255)
                if allExistingGrown then
                    mode = "* smart > new slots"
                else
                    mode = string.format("* smart > existing %d/%d", slotsGrownThisCycle, originalSlotCount)
                end
            elseif growExistingSlots then
                mode = "* growing existing"
                col = Color3.fromRGB(80, 200, 120)
            elseif growNewSlots then
                mode = "* growing new"
                col = Color3.fromRGB(255, 150, 80)
            else
                mode = "* idle"
                col = Color3.fromRGB(100, 100, 100)
            end
            lblMode.Text = mode
            lblMode.TextColor3 = col
            accent.BackgroundColor3 = col
        end
    end)

    -- ============================================================
    -- MENU-STUCK WATCHDOG
    -- If character has no GrowthPercentage for 90s while a mode is active,
    -- assume stuck in menu and respawn the current slot (or slot 1 as fallback)
    -- ============================================================
    task.spawn(function()
        local stuckTimer = 0
        local STUCK_THRESHOLD = 90

        local parkStuckTimer = 0
        local PARK_STUCK_THRESHOLD = 90

        while true do
            task.wait(15)

            local ch = player.Character
            local hasRoot   = ch and ch:FindFirstChild("HumanoidRootPart") ~= nil
            local hasGrowth = ch and ch:GetAttribute("GrowthPercentage") ~= nil

            -- PARKING MODE recovery — separate fast path, don't skip it
            if parkingMode then
                if not hasRoot or not hasGrowth then
                    parkStuckTimer = parkStuckTimer + 15
                    warn(string.format("[Watchdog] [Park] No character for %ds — recovering slot 1", parkStuckTimer))
                    if parkStuckTimer >= PARK_STUCK_THRESHOLD then
                        parkStuckTimer = 0
                        warn("[Watchdog] [Park] Recovering — respawning slot 1 for passive coins")
                        if isLooping then
                            forceUnlockGrowthLoop("parking menu watchdog")
                        end
                        task.spawn(doParkOnSlotOne)
                    end
                else
                    parkStuckTimer = 0
                end
                continue
            end

            local anyModeOn = growExistingSlots or growNewSlots
            if not anyModeOn then
                stuckTimer = 0
                continue
            end

            -- Normal mode: only trigger if character is MISSING entirely (in menu)
            -- NOT if growth is just ticking slowly — growth can take 4+ min per tick
            if not hasRoot or not hasGrowth then
                stuckTimer = stuckTimer + 15
                warn(string.format("[Watchdog] No character/growth for %ds — stuck in menu?", stuckTimer))

                if stuckTimer >= STUCK_THRESHOLD then
                    stuckTimer = 0
                    if isLooping then
                        forceUnlockGrowthLoop("menu watchdog")
                    end
                    local getFirstExistingSlotRecord = shared._getFirstExistingSlotRecord
                    local fallbackEntry = type(getFirstExistingSlotRecord) == "function"
                        and getFirstExistingSlotRecord()
                        or nil
                    local recoverSlot = currentGrowthName or (fallbackEntry and fallbackEntry.CharacterName)
                    warn("[Watchdog] Stuck threshold reached — recovering slot: " .. tostring(recoverSlot))

                    withLock(function()
                        if shared._autoEatChecked then shared._autoEatChecked(false) end
                        if shared._autoDrinkChecked then shared._autoDrinkChecked(false) end

                        local spawnOk = spawnAndSetup(recoverSlot)
                        if not spawnOk then
                            warn("[Watchdog] spawnAndSetup failed for: " .. tostring(recoverSlot))
                            return
                        end

                        task.wait(1)
                        local newCh = player.Character
                        if newCh then
                            local g = waitForAttribute(newCh, "GrowthPercentage", 8)
                            local animal, gender, skin = getSlotInfo(newCh)
                            currentAnimalName = animal
                            currentGender = gender
                            currentSkin = skin
                            if g and g >= 1 then
                                print("[Watchdog] Recovered slot already 100% — triggering next cycle")
                                if growExistingSlots then
                                    task.spawn(doExistingSlotCycle)
                                elseif growNewSlots then
                                    task.spawn(doGrowthReset)
                                end
                                return
                            end
                            print("[Watchdog] Recovery slot info — Animal:", animal, "| Gender:", gender, "| Skin:", skin)
                            task.wait(1)
                        end

                        teleportAndEnable(nil, recoverSlot)
                        currentGrowthName = recoverSlot
                        shared._currentGrowthName = recoverSlot
                        print("[Watchdog] Recovery complete — now growing: " .. tostring(recoverSlot))
                    end)
                end
            else
                stuckTimer = 0
            end
        end
    end)

    -- ============================================================
    -- EAT/DRINK RELIABILITY WATCHDOG
    -- If food OR water drops to 40% or below, cycle off->on
    -- Then wait 15s and check again — if still not recovering, cycle again
    -- IMPORTANT: Only runs for Lion/Tiger (since they're the only ones using
    -- auto eat carcass). Cycles AUTO EAT CARCASS + AUTO DRINK only, never auto eat.
    -- ============================================================
    task.spawn(function()
        local LOW_THRESHOLD  = 40   -- % that triggers the kick
        local RECHECK_WAIT   = 15   -- seconds to wait before re-checking
        local inCycle        = false -- prevent overlapping cycles

        while true do
            task.wait(5)

            -- Only run if not mid-loop and a mode is active
            if isLooping or inCycle then continue end

            local ch = player.Character
            if not ch then continue end

            -- LION/TIGER ONLY — no watchdog cycling for other animals
            local animalName = ch:GetAttribute("AnimalName") or ""
            if animalName ~= "Lion" and animalName ~= "Tiger" then continue end

            local food  = ch:GetAttribute("Food")
            local water = ch:GetAttribute("Water")
            if not food or not water then continue end

            -- Only kick if carcass eat or drink are wired up
            local carcassOn = shared._autoEatCarcassChecked ~= nil
            local drinkOn   = shared._autoDrinkChecked ~= nil
            if not carcassOn and not drinkOn then continue end

            if food <= LOW_THRESHOLD or water <= LOW_THRESHOLD then
                inCycle = true
                local triggerStat = food <= LOW_THRESHOLD and "Food" or "Water"
                local triggerVal  = food <= LOW_THRESHOLD and food or water
                warn(string.format("[EatDrinkWatchdog] [%s] %s at %.1f%% — cycling carcass/drink", animalName, triggerStat, triggerVal))

                -- Cycle off -> on (CARCASS + DRINK only, NEVER auto eat)
                if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(false) end
                if shared._autoDrinkChecked      then shared._autoDrinkChecked(false)      end
                task.wait(1)
                if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(true)  end
                if shared._autoDrinkChecked      then shared._autoDrinkChecked(true)       end
                print("[EatDrinkWatchdog] Cycled ON — waiting " .. RECHECK_WAIT .. "s to verify recovery")

                task.wait(RECHECK_WAIT)

                -- Re-check
                local ch2    = player.Character
                local food2  = ch2 and ch2:GetAttribute("Food")
                local water2 = ch2 and ch2:GetAttribute("Water")

                if food2 and water2 then
                    local stillLow = food2 <= LOW_THRESHOLD or water2 <= LOW_THRESHOLD
                    if stillLow then
                        warn(string.format("[EatDrinkWatchdog] Still low after %ds (Food:%.1f Water:%.1f) — cycling again", RECHECK_WAIT, food2, water2))
                        if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(false) end
                        if shared._autoDrinkChecked      then shared._autoDrinkChecked(false)      end
                        task.wait(1)
                        if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(true)  end
                        if shared._autoDrinkChecked      then shared._autoDrinkChecked(true)       end
                        print("[EatDrinkWatchdog] Second cycle done")
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
-- Safety Net: Fall-through map detection
task.spawn(function()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local player = Players.LocalPlayer

    -- Auto-detect safe position and danger threshold per game
    local GAME_SAFETY = {
        [18214855317]    = { dangerY = -100, safePos = Vector3.new(-6245.2, 10.0, 4664.3) },
        [6174994284]     = { dangerY = -100, safePos = Vector3.new(-6245.2, 10.0, 4664.3) },
        [9237322219] = { dangerY = -100, safePos = Vector3.new(1166.8350830078125, 24.75099754333496, -358.32073974609375) },
    }
    local safeCfg = GAME_SAFETY[game.GameId] or { dangerY = -100, safePos = Vector3.new(-6245.2, 10.0, 4664.3) }
    local DANGER_Y = safeCfg.dangerY
    local SAFE_POS = safeCfg.safePos

    RunService.Heartbeat:Connect(function()
        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        if root.Position.Y < DANGER_Y then
            print("[SafetyNet] Fell through map! Teleporting back...")
            char:SetPrimaryPartCFrame(CFrame.new(SAFE_POS))
        end
    end)
end)
