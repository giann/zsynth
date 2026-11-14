const std = @import("std");

pub const Node = opaque {
    pub const Type = enum {
        column,
        row,
        split,
        grid,
        box,
        panel,
        tabs,
        sidetabs,
        sidebar,
        nodeeditor,
        graphnode,
        areaheader,
        scroll,
        scrollbar,
        label,
        separator,
        progress,
        button,
        toggle,
        checkbox,
        decorator,
        text,
        search,
        hotkey,
        number,
        slider,
        dropdown,
        @"enum",
        swatch,
        popover,
        menubutton,
        menubar,
        list,
        tree,
        gridview,
        ramp,
        curve,
        normal,
        histogram,
        frame,
        radio,
        canvas,
        textarea,
        image,
        meter,
        custom,
        video,
        filebrowser,
    };

    pub const PropertyKey = enum {
        viewevents,
        enabled,
        visible,
        value,
        set_value,
        default,
        min,
        max,
        step,
        precision,
        weight,
        fill,
        factor,
        spacing,
        padding,
        columns,
        rows,
        tile,
        height,
        split,
        scroll,
        scroll_x,
        selmode,
        text_color,
        font_scale,
        cursor,
        current,
        icon,
    };

    extern fn BK_node_new(type: [:0]const u8) callconv(.c) *Node;
    pub fn new(node_type: Type) *Node {
        return BK_node_new(@tagName(node_type));
    }

    extern fn BK_set_num(n: *Node, key: [:0]const u8, v: f64) callconv(.c) c_int;
    pub fn setNum(n: *Node, key: PropertyKey, value: f64) bool {
        return BK_set_num(n, @tagName(key), value) == 1;
    }

    extern fn BK_set_str(n: *Node, key: [:0]const u8, v: [:0]const u8) callconv(.c) c_int;
    pub fn setStr(n: *Node, key: PropertyKey, value: [:0]const u8) bool {
        return BK_set_str(n, @tagName(key), value) == 1;
    }

    extern fn BK_node_add(parent: *Node, child: *Node, index: c_int) callconv(.c) c_int;
    pub const add = BK_node_add;

    pub fn append(parent: *Node, child: *Node) bool {
        return BK_node_add(parent, child, -1) == 1;
    }
};
